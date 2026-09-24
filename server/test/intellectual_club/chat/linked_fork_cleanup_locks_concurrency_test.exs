defmodule IntellectualClub.Chat.LinkedForkCleanupLocksConcurrencyTest do
  use ExUnit.Case, async: false

  import IntellectualClub.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ForkHistoryCorruptFixture
  alias IntellectualClub.Chat.LinkedForkCleanupLocks, as: Locks
  alias IntellectualClub.Chat.LinkedForkCleanupLocksHelper, as: LocksHelper
  alias IntellectualClub.Chat.LinkedForkCleanupLocksTaskFixture
  alias IntellectualClub.Chat.LinkedForkCleanupLocksUsageFixture
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClub.Repo

  require Ash.Query

  @timeout 10_000

  setup do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        %{user: actor} = user_fixture(%{username: "cleanup-locks-#{Ecto.UUID.generate()}"})
        source = anchor!(actor)
        child = anchor!(actor, linked_chat!(source, actor))
        nested = anchor!(actor, linked_chat!(child, actor))
        sibling_source = anchor!(actor, source.chat)
        sibling = anchor!(actor, linked_chat!(sibling_source, actor))
        usage = usage!(nested, actor)
        task = background_task!(source, child.chat, actor)

        %{
          actor: actor,
          source: source,
          child: child,
          nested: nested,
          sibling: sibling,
          usage: usage,
          task: task
        }
      end)

    on_exit(fn -> cleanup_fixture!(fixture.actor) end)
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:intellectual_club, :repo, :query],
        &__MODULE__.pause_after_lock/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    fixture
  end

  test "source-step cleanup fences nested messages before touching their usage", fixture do
    assert_usage_race!(ChatMessageStep, fixture.source.step, fixture)

    Sandbox.unboxed_run(Repo, fn ->
      assert Ash.get!(Chat, fixture.source.chat.id, actor: fixture.actor)
      assert Ash.get!(Chat, fixture.sibling.chat.id, actor: fixture.actor)
      assert_missing!(Chat, fixture.child.chat.id, fixture.actor)
      assert_missing!(Chat, fixture.nested.chat.id, fixture.actor)
    end)
  end

  test "chat cleanup fences every descendant message before clearing chat usage", fixture do
    assert_usage_race!(Chat, fixture.source.chat, fixture)

    Sandbox.unboxed_run(Repo, fn ->
      assert_missing!(Chat, fixture.source.chat.id, fixture.actor)
      assert_missing!(Chat, fixture.nested.chat.id, fixture.actor)
    end)
  end

  test "direct child deletion fences a parent task's lifecycle message before its envelope",
       fixture do
    %{actor: actor, source: source, child: child, task: task} = fixture
    assert_task_race!(Chat, child.chat, fixture)

    Sandbox.unboxed_run(Repo, fn ->
      retained = Ash.get!(BackgroundTask, task.id, actor: actor)
      assert retained.target_chat_id == nil
      assert retained.source_chat_id == source.chat.id
      assert retained.source_message_id == source.message.id
      assert retained.lifecycle_message_id == source.message.id
      assert_missing!(Chat, child.chat.id, actor)
    end)
  end

  test "source-chat cleanup waits for mark_running before detaching its task", fixture do
    assert_task_race!(Chat, fixture.source.chat, fixture)

    Sandbox.unboxed_run(Repo, fn ->
      retained = Ash.get!(BackgroundTask, fixture.task.id, actor: fixture.actor)
      assert retained.status == :canceled
      assert retained.source_chat_id == nil
      assert retained.lifecycle_message_id == nil
      assert retained.target_chat_id == nil
    end)
  end

  test "message-fenced first usage insertion is not blocked by an early chat FK lock", fixture do
    parent = self()
    %{actor: actor, nested: nested, source: source, usage: usage} = fixture

    Sandbox.unboxed_run(Repo, fn ->
      LinkedForkCleanupLocksUsageFixture
      |> Ash.get!(usage.id, actor: actor)
      |> Ash.destroy!(actor: actor)
    end)

    writer =
      db_task!(:first_usage_writer, fn ->
        pause_next_lock("chat_messages", parent)

        Lease.with_token_fence(nested.message.id, nested.message.generation_fence_token, fn ->
          usage!(nested, actor)
        end)
      end)

    assert_receive {:lock_barrier, writer_pid, writer_backend}, @timeout
    assert writer_pid == writer.pid
    cleanup = delete_task!(Chat, source.chat, actor, parent)
    assert_receive {:cleanup_backend, cleanup_backend}, @timeout
    assert cleanup_backend != writer_backend
    send(writer.pid, {:continue_after_block, cleanup_backend})

    assert {:ok, %LlmUsageRecord{} = written} = finish!(writer)
    assert {:ok, :deleted} = finish!(cleanup)

    Sandbox.unboxed_run(Repo, fn ->
      retained = Ash.get!(LlmUsageRecord, written.id, actor: actor)
      assert retained.chat_id == nil
      assert retained.chat_message_id == nil
      assert retained.chat_message_step_id == nil
      assert retained.chat_message_step_id_snapshot == nested.step.id
      assert retained.cost == 0.25
    end)
  end

  test "direct message deletion takes its chat fence before the message fence", fixture do
    parent = self()
    actor = fixture.actor
    nested = Sandbox.unboxed_run(Repo, fn -> anchor!(actor) end)

    writer =
      db_task!(:chat_fenced_writer, fn ->
        pause_next_lock("chats", parent)

        Lease.with_token_chat_fence(
          nested.message.id,
          nested.chat.id,
          nested.message.generation_fence_token,
          fn -> :persisted end
        )
      end)

    assert_receive {:lock_barrier, writer_pid, writer_backend}, @timeout
    assert writer_pid == writer.pid
    cleanup = delete_task!(ChatMessage, nested.message, actor, parent)
    assert_receive {:cleanup_backend, cleanup_backend}, @timeout
    assert cleanup_backend != writer_backend
    send(writer.pid, {:continue_after_block, cleanup_backend})

    assert {:ok, :persisted} = finish!(writer)
    assert {:ok, :deleted} = finish!(cleanup)

    Sandbox.unboxed_run(Repo, fn ->
      assert Ash.get!(Chat, nested.chat.id, actor: actor).last_message_id == nil
      assert_missing!(ChatMessage, nested.message.id, actor)
    end)
  end

  test "preflight before a nested retry fence serializes with source deletion", fixture do
    parent = self()
    %{actor: actor, source: source, child: child} = fixture

    retry =
      db_task!(:nested_retry, fn ->
        Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
          assert LocksHelper.lock!(ChatMessageStep, child.step, actor).id == child.step.id
          send(parent, {:retry_preflight, self(), backend_pid!()})

          receive do
            {:continue_after_block, cleanup_backend} ->
              await_blocked!(cleanup_backend, backend_pid!())
          after
            @timeout -> flunk("Missing source-delete barrier")
          end

          Lease.with_token_chat_fence(
            child.message.id,
            child.chat.id,
            child.message.generation_fence_token,
            fn -> Ash.destroy!(child.step, actor: actor) end
          )
        end)
      end)

    assert_receive {:retry_preflight, retry_pid, retry_backend}, @timeout
    assert retry_pid == retry.pid
    cleanup = delete_task!(ChatMessageStep, source.step, actor, parent)
    assert_receive {:cleanup_backend, cleanup_backend}, @timeout
    assert cleanup_backend != retry_backend
    send(retry.pid, {:continue_after_block, cleanup_backend})

    assert {:ok, {:ok, :ok}} = finish!(retry)
    assert {:ok, :deleted} = finish!(cleanup)
  end

  test "source-step preflight does not lock an independent sibling fork", fixture do
    parent = self()
    %{actor: actor, source: source, sibling: sibling} = fixture

    holder =
      db_task!(:scoped_preflight, fn ->
        Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
          assert LocksHelper.lock!(ChatMessageStep, source.step, actor).id == source.step.id
          send(parent, {:preflight_held, self(), backend_pid!()})

          receive do
            :release -> :ok
          after
            @timeout -> flunk("Missing scoped-lock release")
          end
        end)
      end)

    assert_receive {:preflight_held, holder_pid, holder_backend}, @timeout
    assert holder_pid == holder.pid

    observer =
      db_task!(:unrelated_chat, fn ->
        Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
          assert backend_pid!() != holder_backend

          for {resource, record} <- [{Chat, sibling.chat}, {ChatMessage, sibling.message}] do
            current =
              resource
              |> Ash.Query.filter(id == ^record.id)
              |> Ash.Query.lock("FOR UPDATE NOWAIT")
              |> Ash.read_one!(actor: actor)

            assert current.id == record.id
          end

          :unrelated_rows_remain_available
        end)
      end)

    assert {:ok, :unrelated_rows_remain_available} = finish!(observer)
    send(holder.pid, :release)
    assert {:ok, :ok} = finish!(holder)
  end

  test "cyclic ancestor metadata is rejected without acquiring cleanup locks", fixture do
    Sandbox.unboxed_run(Repo, fn ->
      %{actor: actor, source: source} = fixture
      corrupt = Ash.get!(ForkHistoryCorruptFixture, source.chat.id, actor: actor)

      try do
        corrupt
        |> Ash.Changeset.for_update(:corrupt_anchor, %{parent_chat_id: source.chat.id},
          actor: actor
        )
        |> Ash.update!(actor: actor)

        assert_raise ArgumentError, "Cycle in linked fork cleanup dependencies", fn ->
          Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
            LocksHelper.lock!(ChatMessageStep, source.step, actor)
          end)
        end
      after
        corrupt
        |> Ash.Changeset.for_update(:corrupt_anchor, %{parent_chat_id: nil}, actor: actor)
        |> Ash.update!(actor: actor)
      end
    end)
  end

  test "preflight refuses an actor other than the record owner", fixture do
    Sandbox.unboxed_run(Repo, fn ->
      assert_raise ArgumentError,
                   "Only the owner can lock linked fork cleanup dependencies",
                   fn ->
                     Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
                       LocksHelper.lock!(Chat, fixture.source.chat, nil)
                     end)
                   end
    end)
  end

  defp assert_task_race!(resource, record, fixture) do
    parent = self()
    %{actor: actor, task: task} = fixture

    task =
      Sandbox.unboxed_run(Repo, fn ->
        task
        |> Ash.Changeset.for_update(:update_state, %{status: :queued}, actor: actor)
        |> Ash.update!(actor: actor)
      end)

    writer =
      db_task!(:mark_running, fn ->
        pause_next_lock("chat_messages", parent)
        BackgroundTasks.mark_running(task)
      end)

    assert_receive {:lock_barrier, writer_pid, writer_backend}, @timeout
    assert writer_pid == writer.pid
    cleanup = delete_task!(resource, record, actor, parent)
    assert_receive {:cleanup_backend, cleanup_backend}, @timeout
    assert cleanup_backend != writer_backend
    send(writer.pid, {:continue_after_block, cleanup_backend})

    assert {:ok, %BackgroundTask{status: :canceled}} = finish!(writer)
    assert {:ok, :deleted} = finish!(cleanup)
  end

  defp assert_usage_race!(resource, record, fixture) do
    parent = self()
    %{actor: actor, nested: nested, usage: usage} = fixture

    writer =
      db_task!(:usage_writer, fn ->
        pause_next_lock("chat_messages", parent)

        Lease.with_token_fence(
          nested.message.id,
          nested.message.generation_fence_token,
          fn ->
            usage
            |> Ash.Changeset.for_update(:update, %{output_tokens: 73, cost: 0.75}, actor: actor)
            |> Ash.update!(actor: actor)

            :persisted
          end
        )
      end)

    assert_receive {:lock_barrier, writer_pid, writer_backend}, @timeout
    assert writer_pid == writer.pid
    cleanup = delete_task!(resource, record, actor, parent)
    assert_receive {:cleanup_backend, cleanup_backend}, @timeout
    assert cleanup_backend != writer_backend
    send(writer.pid, {:continue_after_block, cleanup_backend})

    assert {:ok, :persisted} = finish!(writer)
    assert {:ok, :deleted} = finish!(cleanup)

    Sandbox.unboxed_run(Repo, fn ->
      retained = Ash.get!(LlmUsageRecord, usage.id, actor: actor)
      assert retained.output_tokens == 73
      assert retained.cost == 0.75
      assert retained.chat_id == nil
      assert retained.chat_message_id == nil
      assert retained.chat_message_step_id == nil
      assert retained.chat_message_step_id_snapshot == nested.step.id
    end)
  end

  defp delete_task!(resource, record, actor, parent) do
    db_task!(:cleanup, fn ->
      Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
        send(parent, {:cleanup_backend, backend_pid!()})

        # Exercise preflight and the real cascade in one transaction, including
        # the reentrant calls made by cleanup prepare/1 after integration.
        current = LocksHelper.lock!(resource, record, actor)
        Ash.destroy!(current, actor: actor)
        :deleted
      end)
    end)
  end

  defp db_task!(name, fun) do
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

    %{pid: pid, ref: ref, monitor: Process.monitor(pid), name: name}
  end

  defp finish!(%{pid: pid, ref: ref, monitor: monitor}) do
    assert_receive {:db_result, ^ref, result}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, @timeout
    assert reason in [:normal, :noproc]
    result
  end

  defp pause_next_lock(table, parent) do
    Process.put({__MODULE__, :barrier}, {table, parent})
  end

  @doc false
  def pause_after_lock(_event, _measurements, metadata, _config) do
    case Process.get({__MODULE__, :barrier}) do
      {table, parent} ->
        if String.contains?(metadata.query, ~s(FROM "#{table}")) and
             String.contains?(metadata.query, ["FOR UPDATE", "FOR NO KEY UPDATE"]) do
          Process.delete({__MODULE__, :barrier})
          blocker = backend_pid!()
          send(parent, {:lock_barrier, self(), blocker})

          receive do
            {:continue_after_block, waiter} -> await_blocked!(waiter, blocker)
          after
            @timeout -> raise "Missing cleanup lock barrier"
          end
        end

      nil ->
        :ok
    end
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp await_blocked!(waiter, blocker) do
    await_blocked!(waiter, blocker, System.monotonic_time(:millisecond) + @timeout)
  end

  defp await_blocked!(waiter, blocker, deadline) do
    # Observe PostgreSQL's actual wait graph using the holder's connection. No
    # third workload connection, scheduler timing assumption, or sleep is needed.
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [blocker, waiter])

    unless blocked? do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Cleanup did not wait for the expected database fence")
      end

      await_blocked!(waiter, blocker, deadline)
    end
  end

  defp anchor!(actor, chat \\ nil) do
    chat = chat || create_chat!(actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{chat_id: chat.id, role: :assistant, status: :done},
        actor: actor
      )
      |> Ash.Changeset.force_change_attribute(:generation_fence_token, Ecto.UUID.generate())
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

    %{chat: chat, message: message, step: step, item: item}
  end

  defp create_chat!(actor) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
    |> Ash.create!(actor: actor)
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
      fork_task: "Lock order regression fixture"
    })
    |> Ash.create!(actor: actor)
  end

  defp usage!(anchor, actor) do
    LlmUsageRecord
    |> Ash.Changeset.for_create(
      :create,
      %{
        usage_user_id: actor.id,
        usage_user_id_snapshot: actor.id,
        usage_username_snapshot: actor.username,
        configuration_owner_id_snapshot: actor.id,
        llm_configuration_id_snapshot: 1,
        llm_configuration_label_snapshot: "Lock fixture",
        chat_id: anchor.chat.id,
        chat_id_snapshot: anchor.chat.id,
        chat_message_id: anchor.message.id,
        chat_message_id_snapshot: anchor.message.id,
        chat_message_step_id: anchor.step.id,
        chat_message_step_id_snapshot: anchor.step.id,
        step_sequence: 1,
        occurred_at: DateTime.utc_now(),
        cost: 0.25,
        output_tokens: 25
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp background_task!(source, target, actor) do
    BackgroundTask
    |> Ash.Changeset.for_create(
      :create,
      %{
        kind: "fork",
        adapter: "cleanup_lock_test",
        status: :completed,
        function_name: "fork",
        source_chat_id: source.chat.id,
        source_message_id: source.message.id,
        lifecycle_message_id: source.message.id,
        source_step_id: source.step.id,
        source_tool_call_item_id: source.item.id,
        target_chat_id: target.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp assert_missing!(resource, id, actor) do
    assert {:ok, nil} = resource |> Ash.Query.filter(id == ^id) |> Ash.read_one(actor: actor)
  end

  defp cleanup_fixture!(actor) do
    Sandbox.unboxed_run(Repo, fn ->
      for resource <- [LinkedForkCleanupLocksTaskFixture, LinkedForkCleanupLocksUsageFixture] do
        resource |> Ash.read!(actor: actor) |> Enum.each(&Ash.destroy!(&1, actor: actor))
      end

      Chat
      |> Ash.Query.filter(owner_id == ^actor.id)
      |> Ash.Query.sort(id: :desc)
      |> Ash.read!(actor: actor)
      |> Enum.each(&Ash.destroy!(&1, actor: actor))

      # Account fixtures are bootstrapped without an administrator; dispose of
      # only this test's account using the same fixture-only authorization bypass.
      actor
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!(authorize?: false)
    end)
  end
end
