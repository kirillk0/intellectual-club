defmodule IntellectualClub.Chat.LinkedForkReparentConcurrencyTest do
  use ExUnit.Case, async: false

  import IntellectualClub.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ForkHistory
  alias IntellectualClub.Chat.ForkHistoryCorruptFixture
  alias IntellectualClub.Chat.LinkedForkCleanup
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Repo

  require Ash.Query

  @timeout 10_000

  setup do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        %{user: actor} = user_fixture(%{username: "reparent-locks-#{Ecto.UUID.generate()}"})
        chat = create_chat!(actor)
        parent = anchor!(chat, nil, actor)

        {:ok, deleted} =
          Threads.add_message(chat, :user, "Remove only this message",
            actor: actor,
            parent_id: parent.message.id
          )

        stale_chat = Ash.get!(Chat, chat.id, actor: actor)
        child = anchor!(chat, deleted.id, actor)
        %{actor: actor, chat: stale_chat, parent: parent, deleted: deleted, child: child}
      end)

    on_exit(fn -> cleanup_fixture!(fixture.actor) end)
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:intellectual_club, :repo, :query],
        &__MODULE__.pause_after_query/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    fixture
  end

  @tag :reparent_lock_race
  test "retry prelock blocks deletion before its first reparent or active-leaf mutation",
       fixture do
    parent = self()
    %{actor: actor, chat: chat, deleted: deleted, child: child} = fixture
    before = Sandbox.unboxed_run(Repo, fn -> tree_state!(chat, actor) end)

    retry =
      db_task!(fn ->
        pause_next_query(:chat_lock, parent, fn -> tree_state!(chat, actor) end)
        retry!(fixture, parent)
      end)

    assert_receive {:query_barrier, retry_pid, retry_backend}, @timeout
    assert retry_pid == retry.pid
    assert_receive {:retry_backend, ^retry_backend}, @timeout
    deletion = delete_task!(fixture, parent)
    assert_receive {:delete_backend, delete_backend}, @timeout
    assert delete_backend != retry_backend
    send(retry.pid, {:continue_after_block, delete_backend})

    assert_receive {:blocked_query, ^retry_pid, ^delete_backend, query, observed}, @timeout
    assert query =~ ~s(FROM "chats")
    assert query =~ "FOR NO KEY UPDATE"
    assert observed == before
    assert {:ok, replacement_id} = finish!(retry)
    assert is_integer(replacement_id)
    assert {:ok, branch} = finish!(deletion)
    assert Enum.map(branch, & &1.id) == [fixture.parent.message.id, child.message.id]

    Sandbox.unboxed_run(Repo, fn ->
      assert_deleted_and_reparented!(fixture)
      assert_missing!(ChatMessageStep, fixture.parent.step.id, actor)

      assert Ash.get!(ChatMessageStep, replacement_id, actor: actor).chat_message_id ==
               fixture.parent.message.id

      assert_missing!(ChatMessage, deleted.id, actor)
    end)
  end

  @tag :reparent_lock_race
  test "deletion retains its chat fence across reparent until destroy when retry arrives",
       fixture do
    parent = self()

    deletion =
      db_task!(fn ->
        pause_next_query(:reparent, parent)
        Threads.delete_message_keep_children(fixture.chat.id, fixture.deleted.id, fixture.actor)
      end)

    assert_receive {:query_barrier, delete_pid, delete_backend}, @timeout
    assert delete_pid == deletion.pid
    retry = db_task!(fn -> retry!(fixture, parent) end)
    assert_receive {:retry_backend, retry_backend}, @timeout
    assert retry_backend != delete_backend
    send(deletion.pid, {:continue_after_block, retry_backend})

    assert_receive {:blocked_query, ^delete_pid, ^retry_backend, query, :ok}, @timeout
    # Waiting on messages here would mean reparent acquired its child/FK locks
    # before the common chat fence, recreating the retry/delete inversion.
    assert query =~ ~s(FROM "chats")
    assert query =~ "FOR NO KEY UPDATE"
    assert {:ok, branch} = finish!(deletion)
    assert Enum.map(branch, & &1.id) == [fixture.parent.message.id, fixture.child.message.id]
    assert {:ok, replacement_id} = finish!(retry)
    assert is_integer(replacement_id)
    Sandbox.unboxed_run(Repo, fn -> assert_deleted_and_reparented!(fixture) end)
  end

  test "chat and messages are reread after waiting for the common fence", fixture do
    parent = self()
    %{actor: actor, chat: chat, deleted: deleted, child: child} = fixture

    holder =
      db_task!(fn ->
        Ash.transaction([Chat, ChatMessage], fn ->
          pause_next_query(:chat_lock, parent, fn ->
            child.message
            |> Ash.Changeset.for_update(:reparent, %{parent_id: fixture.parent.message.id},
              actor: actor
            )
            |> Ash.update!(actor: actor)

            chat
            |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: deleted.id},
              actor: actor
            )
            |> Ash.update!(actor: actor)

            :changed_branch
          end)

          lock_chat!(chat, actor)
        end)
      end)

    assert_receive {:query_barrier, holder_pid, holder_backend}, @timeout
    assert holder_pid == holder.pid
    deletion = delete_task!(fixture, parent)
    assert_receive {:delete_backend, delete_backend}, @timeout
    assert delete_backend != holder_backend
    send(holder.pid, {:continue_after_block, delete_backend})
    assert_receive {:blocked_query, ^holder_pid, ^delete_backend, _, :changed_branch}, @timeout
    assert {:ok, %Chat{}} = finish!(holder)
    assert {:ok, branch} = finish!(deletion)
    assert Enum.map(branch, & &1.id) == [fixture.parent.message.id, child.message.id]
    Sandbox.unboxed_run(Repo, fn -> assert_deleted_and_reparented!(fixture) end)
  end

  test "stale chat structs do not replace the surviving active leaf", fixture do
    Sandbox.unboxed_run(Repo, fn ->
      assert fixture.chat.last_message_id == fixture.deleted.id

      assert {:ok, branch} =
               Threads.delete_message_keep_children(
                 fixture.chat,
                 fixture.deleted.id,
                 fixture.actor
               )

      assert Enum.map(branch, & &1.id) == [fixture.parent.message.id, fixture.child.message.id]
      assert_deleted_and_reparented!(fixture)
    end)
  end

  test "missing messages and role mixing preserve their API errors without mutations", fixture do
    Sandbox.unboxed_run(Repo, fn ->
      %{actor: actor, chat: chat, parent: parent, deleted: deleted} = fixture
      foreign_chat = create_chat!(actor)
      before = tree_state!(chat, actor)

      assert {:error, :message_not_found} =
               Threads.delete_message_keep_children(chat.id, -1, actor)

      assert {:error, :message_not_found} =
               Threads.delete_message_keep_children(foreign_chat.id, deleted.id, actor)

      assert tree_state!(chat, actor) == before

      {:ok, _sibling} =
        Threads.add_message(chat, :user, "Another branch",
          actor: actor,
          parent_id: parent.message.id
        )

      before = tree_state!(chat, actor)

      assert {:error, :cannot_mix_roles} =
               Threads.delete_message_keep_children(chat.id, deleted.id, actor)

      assert tree_state!(chat, actor) == before
    end)
  end

  test "linked child rejection rolls back the active leaf and every reparent", fixture do
    Sandbox.unboxed_run(Repo, fn ->
      actor = fixture.actor
      linked = linked_chat!(fixture.parent, actor)
      local_parent = anchor!(linked, nil, actor)

      {:ok, deleted} =
        Threads.add_message(linked, :user, "Read-only local history",
          actor: actor,
          parent_id: local_parent.message.id
        )

      first_child = anchor!(linked, deleted.id, actor)
      second_child = anchor!(linked, deleted.id, actor)

      linked
      |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: deleted.id}, actor: actor)
      |> Ash.update!(actor: actor)

      before = tree_state!(linked, actor)
      inherited = ForkHistory.prefix(linked, actor)
      assert {:ok, [_]} = inherited

      delete = fn -> Threads.delete_message_keep_children(linked.id, deleted.id, actor) end

      for operation <- [delete, fn -> Ash.transaction(ChatMessage, delete) end] do
        assert {:error, %Ash.Error.Invalid{} = error} = operation.()
        assert Exception.message(error) =~ "Linked fork history is read-only"
        assert tree_state!(linked, actor) == before
        assert ForkHistory.prefix(linked, actor) == inherited

        for child <- [first_child, second_child] do
          assert Ash.get!(ChatMessage, child.message.id, actor: actor).parent_id == deleted.id
        end
      end
    end)
  end

  test "source deletion preserves retained descendants and unrelated inherited history",
       fixture do
    Sandbox.unboxed_run(Repo, fn ->
      %{actor: actor, parent: parent, deleted: deleted, child: child} = fixture
      dependent = linked_chat!(parent, actor)
      retained = linked_chat!(child, actor)
      unrelated_source = anchor!(create_chat!(actor), nil, actor)
      unrelated = linked_chat!(unrelated_source, actor)
      inherited = ForkHistory.prefix(unrelated, actor)
      assert {:ok, [_]} = inherited

      assert {:ok, prefix} = ForkHistory.prefix(retained, actor)
      assert Enum.map(prefix, & &1.id) == [parent.message.id, deleted.id, child.message.id]

      assert {:ok, branch} =
               Threads.delete_message_keep_children(fixture.chat.id, parent.message.id, actor)

      assert Enum.map(branch, & &1.id) == [deleted.id, child.message.id]
      assert_missing!(Chat, dependent.id, actor)
      assert_missing!(ChatMessage, parent.message.id, actor)
      assert Ash.get!(ChatMessage, deleted.id, actor: actor).parent_id == nil
      assert Ash.get!(ChatMessage, child.message.id, actor: actor).parent_id == deleted.id
      assert {:ok, prefix} = ForkHistory.prefix(retained, actor)
      assert Enum.map(prefix, & &1.id) == [deleted.id, child.message.id]
      assert ForkHistory.prefix(unrelated, actor) == inherited
    end)
  end

  test "cyclic cleanup dependencies return an error without partial deletion", fixture do
    Sandbox.unboxed_run(Repo, fn ->
      %{actor: actor, chat: chat, deleted: deleted} = fixture
      corrupt = Ash.get!(ForkHistoryCorruptFixture, chat.id, actor: actor)
      before = tree_state!(chat, actor)

      try do
        corrupt
        |> Ash.Changeset.for_update(:corrupt_anchor, %{parent_chat_id: chat.id}, actor: actor)
        |> Ash.update!(actor: actor)

        assert {:error, error} = Threads.delete_message_keep_children(chat.id, deleted.id, actor)
        assert Exception.message(error) =~ "Cycle in linked fork cleanup dependencies"

        assert tree_state!(chat, actor) == before
      after
        corrupt
        |> Ash.Changeset.for_update(:corrupt_anchor, %{parent_chat_id: nil}, actor: actor)
        |> Ash.update!(actor: actor)
      end
    end)
  end

  test "a new fork on retained history does not invalidate keep-children deletion",
       fixture do
    parent = self()
    %{actor: actor, chat: chat, child: child} = fixture

    holder =
      db_task!(fn ->
        Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
          pause_next_query(:chat_lock, parent, fn -> linked_chat!(child, actor).id end)
          lock_chat!(chat, actor)
        end)
      end)

    assert_receive {:query_barrier, holder_pid, holder_backend}, @timeout
    assert holder_pid == holder.pid
    deletion = delete_task!(fixture, parent)
    assert_receive {:delete_backend, delete_backend}, @timeout
    assert delete_backend != holder_backend
    send(holder.pid, {:continue_after_block, delete_backend})
    assert_receive {:blocked_query, ^holder_pid, ^delete_backend, _, linked_id}, @timeout
    assert is_integer(linked_id)
    assert {:ok, %Chat{}} = finish!(holder)

    assert {:ok, _branch} = finish!(deletion)

    Sandbox.unboxed_run(Repo, fn ->
      assert_deleted_and_reparented!(fixture)
      assert Ash.get!(Chat, linked_id, actor: actor).fork_source_step_id == child.step.id
    end)
  end

  test "a new dependent of a deleted step still fails closed after waiting", fixture do
    parent = self()
    %{actor: actor, chat: chat, parent: source} = fixture

    holder =
      db_task!(fn ->
        Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
          pause_next_query(:chat_lock, parent, fn -> linked_chat!(source, actor).id end)
          lock_chat!(chat, actor)
        end)
      end)

    assert_receive {:query_barrier, holder_pid, holder_backend}, @timeout

    deletion =
      db_task!(fn ->
        send(parent, {:delete_backend, backend_pid!()})
        Ash.destroy(source.step, actor: actor)
      end)

    assert_receive {:delete_backend, delete_backend}, @timeout
    assert delete_backend != holder_backend
    send(holder.pid, {:continue_after_block, delete_backend})
    assert_receive {:blocked_query, ^holder_pid, ^delete_backend, _, linked_id}, @timeout
    assert {:ok, %Chat{}} = finish!(holder)
    assert {:error, error} = finish!(deletion)
    assert Exception.message(error) =~ "Linked fork cleanup dependencies changed"

    Sandbox.unboxed_run(Repo, fn ->
      assert Ash.get!(ChatMessageStep, source.step.id, actor: actor)
      assert Ash.get!(Chat, linked_id, actor: actor).fork_source_step_id == source.step.id
    end)
  end

  defp retry!(fixture, parent) do
    Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
      send(parent, {:retry_backend, backend_pid!()})

      # Match production's precise preflight and reuse it inside the mutation.
      # No Lease manager RPC or provider is needed for this SQL interleaving.
      LinkedForkCleanup.with_scope(
        {:steps, fixture.parent.message.id, 1},
        fixture.actor,
        fn operation ->
          Persistence.replace_steps_for_retry!(
            fixture.parent.message.id,
            1,
            %{"retry" => true},
            [],
            operation
          )
        end
      )
    end)
  end

  defp delete_task!(fixture, parent) do
    db_task!(fn ->
      send(parent, {:delete_backend, backend_pid!()})
      Threads.delete_message_keep_children(fixture.chat.id, fixture.deleted.id, fixture.actor)
    end)
  end

  defp db_task!(fun) do
    parent = self()
    ref = make_ref()

    pid =
      start_supervised!(%{
        id: ref,
        start:
          {Task, :start_link,
           [
             fn ->
               result =
                 try do
                   Sandbox.unboxed_run(Repo, fun)
                 rescue
                   error -> {:raised, error, __STACKTRACE__}
                 end

               send(parent, {:db_result, ref, result})
             end
           ]},
        restart: :temporary
      })

    %{pid: pid, ref: ref, monitor: Process.monitor(pid)}
  end

  defp finish!(%{pid: pid, ref: ref, monitor: monitor}) do
    assert_receive {:db_result, ^ref, result}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, @timeout
    assert reason in [:normal, :noproc]
    result
  end

  defp pause_next_query(kind, parent, observe \\ fn -> :ok end) do
    Process.put({__MODULE__, :barrier}, {kind, parent, observe})
  end

  @doc false
  def pause_after_query(_event, _measurements, metadata, _config) do
    case Process.get({__MODULE__, :barrier}) do
      {kind, parent, observe} ->
        if barrier_query?(kind, metadata.query) do
          Process.delete({__MODULE__, :barrier})
          blocker = backend_pid!()
          send(parent, {:query_barrier, self(), blocker})

          receive do
            {:continue_after_block, waiter} ->
              query = await_blocked!(waiter, blocker)
              send(parent, {:blocked_query, self(), waiter, query, observe.()})
          after
            @timeout -> raise "Missing reparent lock barrier"
          end
        end

      nil ->
        :ok
    end
  end

  defp barrier_query?(:chat_lock, query) do
    String.contains?(query, ~s(FROM "chats")) and
      String.contains?(query, "FOR NO KEY UPDATE")
  end

  defp barrier_query?(:reparent, query) do
    String.starts_with?(query, ~s(UPDATE "chat_messages")) and
      String.contains?(query, ~s("parent_id"))
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp await_blocked!(waiter, blocker) do
    await_blocked!(waiter, blocker, System.monotonic_time(:millisecond) + @timeout)
  end

  defp await_blocked!(waiter, blocker, deadline) do
    # Use the holder's connection to observe the actual PostgreSQL wait graph;
    # there is no third workload connection, sleep, or scheduler assumption.
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    %{rows: rows} =
      Repo.query!(
        "SELECT query FROM pg_stat_activity WHERE pid = $1::int " <>
          "AND $2::int = ANY(pg_blocking_pids(pid))",
        [waiter, blocker]
      )

    case rows do
      [[query]] ->
        query

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "Operation did not wait on the expected PostgreSQL fence"
        end

        await_blocked!(waiter, blocker, deadline)
    end
  end

  defp tree_state!(chat, actor) do
    messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(actor: actor)

    {Ash.get!(Chat, chat.id, actor: actor).last_message_id,
     Enum.map(messages, &{&1.id, &1.parent_id})}
  end

  defp assert_deleted_and_reparented!(fixture) do
    %{actor: actor, chat: chat, parent: parent, deleted: deleted, child: child} = fixture
    assert_missing!(ChatMessage, deleted.id, actor)
    assert Ash.get!(ChatMessage, child.message.id, actor: actor).parent_id == parent.message.id
    assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == child.message.id
  end

  defp lock_chat!(chat, actor) do
    Chat
    |> Ash.Query.filter(id == ^chat.id)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read_one!(actor: actor)
  end

  defp create_chat!(actor) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp anchor!(chat, parent_id, actor) do
    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{chat_id: chat.id, parent_id: parent_id, role: :assistant, status: :done},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_id: message.id, sequence: 1, response_final: true},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 1, type: :tool_call},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :opaque,
        content_json: %{
          "tool_call_id" => "reparent-call-#{item.id}",
          "name" => "agent__fork",
          "arguments" => %{"task" => "Preserve inherited context"}
        }
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    %{chat: chat, message: message, step: step, item: item}
  end

  defp linked_chat!(source, actor) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        parent_chat_id: source.chat.id,
        parent_message_id: source.message.id,
        parent_tool_call_item_id: source.item.id,
        parent_relation_kind: :fork,
        subagent: true
      },
      actor: actor
    )
    |> Ash.Changeset.force_change_attributes(%{
      fork_source_step_id: source.step.id,
      fork_task: "Preserve inherited context"
    })
    |> Ash.create!(actor: actor)
  end

  defp assert_missing!(resource, id, actor) do
    assert {:ok, nil} = resource |> Ash.Query.filter(id == ^id) |> Ash.read_one(actor: actor)
  end

  defp cleanup_fixture!(actor) do
    Sandbox.unboxed_run(Repo, fn ->
      Chat
      |> Ash.Query.filter(owner_id == ^actor.id)
      |> Ash.Query.sort(id: :desc)
      |> Ash.read!(actor: actor)
      |> Enum.each(&Ash.destroy!(&1, actor: actor))

      actor
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!(authorize?: false)
    end)
  end
end
