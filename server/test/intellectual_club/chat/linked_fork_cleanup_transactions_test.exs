defmodule IntellectualClub.Chat.LinkedForkCleanupTransactionsTest do
  @moduledoc """
  Linked fork cleanup against real PostgreSQL transactions (outside the SQL
  sandbox): runtime side effects wait for the real outer commit and never run
  after a rollback; concurrent writers and cleanup acquire their fences in a
  deadlock-free order (`:whitebox`).

  Every test creates its own committed owner and removes everything it owns
  on exit.
  """

  use ExUnit.Case, async: false

  import IntellectualClub.AccountsFixtures
  import IntellectualClub.Chat.DbRaceHelpers
  import IntellectualClub.Chat.ForkFixtures
  import IntellectualClub.ChatFixtures
  import IntellectualClub.LlmFixtures, only: [create_usage_record!: 2]
  import IntellectualClub.RepoTestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatUploadSession
  alias IntellectualClub.Chat.LinkedForkCleanup
  alias IntellectualClub.Chat.LinkedForkCleanup.TransactionOutcome
  alias IntellectualClub.Chat.LinkedForkCleanupLocksHelper, as: LocksHelper
  alias IntellectualClub.Chat.LinkedForkCleanupLocksUsageFixture
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files.UploadStaging
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClub.Repo

  require Ash.Query

  @timeout 10_000
  @cleanup_supervisor IntellectualClub.BackgroundTasks.ExecutionSupervisor

  describe "outer transaction outcome" do
    setup do
      # Serial, real-commit tests: detached production tasks need their own normal
      # connections, not an inherited/shared Sandbox transaction or an allowance.
      :ok = Sandbox.mode(Repo, :auto)
      on_exit(fn -> Sandbox.mode(Repo, :manual) end)

      fixture =
        Sandbox.unboxed_run(Repo, fn ->
          actor = committed_actor!("cleanup-commit")
          source = create_tool_call_anchor!(actor)
          child = create_tool_call_anchor!(actor, chat: create_linked_chat!(actor, source))
          %{actor: actor, source: source, child: child}
        end)

      on_exit(fn ->
        await_cleanup_jobs!()
        cleanup_committed_owner!(fixture.actor)
        await_cleanup_jobs!()
      end)

      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:intellectual_club, :repo, :query],
          &__MODULE__.observe_outcome/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      fixture
    end

    test "transaction metadata actions are private and require an actor and an existing transaction",
         %{actor: actor} do
      for action <- [:capture, :status] do
        action = Ash.Resource.Info.action(TransactionOutcome, action)
        refute action.public?
        refute action.transaction?
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               TransactionOutcome
               |> Ash.ActionInput.for_action(:capture, %{})
               |> Ash.run_action(authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} = TransactionOutcome.status("1", nil)
      assert {:error, _} = TransactionOutcome.status("not-an-xid", actor)

      Sandbox.unboxed_run(Repo, fn ->
        refute Repo.in_transaction?()

        assert {:error, error} =
                 TransactionOutcome
                 |> Ash.ActionInput.for_action(:capture, %{}, actor: actor)
                 |> Ash.run_action(actor: actor)

        assert Exception.message(error) =~ "requires an existing Repo transaction"

        assert_raise Ash.Error.Unknown, ~r/requires an existing Repo transaction/, fn ->
          TransactionOutcome.capture!(actor)
        end

        refute Repo.in_transaction?()
        refute_receive {:captured, _, _}, 0

        assert {:ok, :checked} =
                 Repo.transaction(fn ->
                   xid = TransactionOutcome.capture!(actor)

                   assert {:ok, ^xid} =
                            Repo.transaction(fn -> TransactionOutcome.capture!(actor) end)

                   assert TransactionOutcome.status!(xid, actor) == :in_progress

                   assert_raise ArgumentError,
                                "Transaction outcome must be awaited outside a Repo transaction",
                                fn ->
                                  TransactionOutcome.await_committed?(xid, actor)
                                end

                   :checked
                 end)
      end)
    end

    test "invalid or future transaction IDs fail closed", %{actor: actor} do
      Sandbox.unboxed_run(Repo, fn ->
        assert {:error, _} = TransactionOutcome.status("18446744073709551615", actor)

        assert_raise Ash.Error.Invalid, fn ->
          TransactionOutcome.await_committed?("invalid", actor)
        end

        assert_raise Ash.Error.Unknown, fn ->
          TransactionOutcome.await_committed?("18446744073709551615", actor)
        end

        refute Repo.in_transaction?()
      end)
    end

    test "active child generation is signaled after deletion without waiting under deletion locks",
         f do
      worker = generation_worker!(f.child.message.id)

      Sandbox.unboxed_run(Repo, fn ->
        Ash.destroy!(f.source.step, actor: f.actor)
        assert_missing!(Chat, f.child.chat.id, f.actor)
      end)

      assert_receive {:canceled, pid}, @timeout
      assert pid == worker.pid
      assert finish!(worker) == :canceled
      await_cleanup_jobs!()
    end

    test "nested runtime work is aggregated once and waits for a real outer commit", f do
      nested =
        Sandbox.unboxed_run(Repo, fn ->
          create_tool_call_anchor!(f.actor, chat: create_linked_chat!(f.actor, f.child))
        end)

      workers = [generation_worker!(f.child.message.id), generation_worker!(nested.message.id)]

      held =
        hold_delete!(
          fn -> Ash.destroy!(f.source.step, actor: f.actor, return_notifications?: true) end,
          f.actor
        )

      Enum.each(workers, &probe_worker!/1)
      refute_receive {:canceled, _}, 0
      release!(held, :commit, f.actor)

      Enum.each(workers, fn worker ->
        pid = worker.pid
        assert_receive {:canceled, ^pid}, @timeout
        assert finish!(worker) == :canceled
      end)

      Sandbox.unboxed_run(Repo, fn ->
        assert_missing!(Chat, f.child.chat.id, f.actor)
        assert_missing!(Chat, nested.chat.id, f.actor)
      end)
    end

    test "an outer rollback preserves the live child and never cancels its worker", f do
      worker = generation_worker!(f.child.message.id)

      held =
        hold_delete!(
          fn -> Ash.destroy!(f.source.step, actor: f.actor, return_notifications?: true) end,
          f.actor
        )

      probe_worker!(worker)
      release!(held, :abort, f.actor)
      probe_worker!(worker)
      refute_receive {:canceled, _}, 0

      Sandbox.unboxed_run(Repo, fn ->
        assert Ash.get!(Chat, f.child.chat.id, actor: f.actor)
        assert Ash.get!(ChatMessageStep, f.source.step.id, actor: f.actor)
      end)
    end

    test "a delayed job from a rolled-back subtree deletion ignores a later keep-children deletion",
         f do
      message =
        Sandbox.unboxed_run(Repo, fn ->
          create_message!(f.actor, f.source.chat, %{
            parent_id: f.source.message.id,
            status: :generating
          })
        end)

      worker = generation_worker!(message.id)
      gate = make_ref()
      handler = {__MODULE__, gate}

      :ok =
        :telemetry.attach(
          handler,
          [:intellectual_club, :repo, :query],
          &__MODULE__.pause_outcome/4,
          {self(), gate}
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      held =
        hold_delete!(
          fn ->
            f.source.message
            |> Ash.Changeset.for_destroy(:destroy_with_children, %{}, actor: f.actor)
            |> Ash.destroy!(actor: f.actor, return_notifications?: true)
          end,
          f.actor
        )

      %{job: job, monitor: monitor} = held
      assert_receive {:outcome_paused, ^job, ^gate}, @timeout
      :ok = :telemetry.detach(handler)
      on_exit(fn -> send(job, {:resume_outcome, gate}) end)
      send(held.holder.pid, :abort)
      assert finish!(held.holder) == {:error, :keep_source}

      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, _} =
                 IntellectualClub.Chat.Threads.delete_message_keep_children(
                   f.source.chat,
                   f.source.message.id,
                   f.actor
                 )

        assert_missing!(ChatMessage, f.source.message.id, f.actor)
        current = Ash.get!(ChatMessage, message.id, actor: f.actor)
        assert current.parent_id == nil
        assert current.status == :generating
        assert TransactionOutcome.status!(held.xid, f.actor) == :aborted
      end)

      send(job, {:resume_outcome, gate})
      assert_receive {:DOWN, ^monitor, :process, ^job, :normal}, @timeout
      probe_worker!(worker)
      refute_receive {:canceled, _}, 0
    end

    test "active task envelopes are detached at commit and canceled without a retained database fence",
         f do
      task =
        Sandbox.unboxed_run(Repo, fn ->
          create_fork_task!(f.actor, f.source, f.child.chat, %{status: :running})
        end)

      worker = background_worker!(task, f)

      held =
        hold_delete!(
          fn -> Ash.destroy!(f.source.step, actor: f.actor, return_notifications?: true) end,
          f.actor
        )

      Sandbox.unboxed_run(Repo, fn ->
        current = Ash.get!(BackgroundTask, task.id, actor: f.actor)
        assert current.status == :running
        refute current.cancel_requested
        assert current.target_chat_id == f.child.chat.id
        assert current.source_step_id == f.source.step.id
      end)

      probe_worker!(worker)
      release!(held, :commit, f.actor)
      pid = worker.pid
      assert_receive {:cancel_state, ^pid, current}, @timeout
      assert current.cancel_requested
      assert current.target_chat_id == nil
      assert current.source_step_id == nil
      assert current.source_tool_call_item_id == nil
      assert current.source_chat_id == f.source.chat.id
      assert current.source_message_id == f.source.message.id
      assert current.lifecycle_message_id == f.source.message.id
      assert current.runner_ref == task.runner_ref
      assert finish!(worker) == :canceled

      Sandbox.unboxed_run(Repo, fn ->
        assert Ash.get!(BackgroundTask, task.id, actor: f.actor).status == :canceled
      end)
    end

    test "outer rollback retains the task envelope and never contacts its runtime", f do
      task =
        Sandbox.unboxed_run(Repo, fn ->
          create_fork_task!(f.actor, f.source, f.child.chat, %{status: :running})
        end)

      worker = background_worker!(task, f)

      held =
        hold_delete!(
          fn -> Ash.destroy!(f.source.step, actor: f.actor, return_notifications?: true) end,
          f.actor
        )

      release!(held, :abort, f.actor)
      probe_worker!(worker)
      refute_receive {:cancel_state, _, _}, 0

      Sandbox.unboxed_run(Repo, fn ->
        current = Ash.get!(BackgroundTask, task.id, actor: f.actor)
        assert current.status == :running
        refute current.cancel_requested

        for field <- [
              :source_chat_id,
              :source_message_id,
              :source_step_id,
              :source_tool_call_item_id,
              :lifecycle_message_id,
              :target_chat_id,
              :runner_ref
            ] do
          assert Map.fetch!(current, field) == Map.fetch!(task, field)
        end
      end)
    end

    for outcome <- [:commit, :abort] do
      @outcome outcome
      test "a root inserted and deleted in the outer transaction honors #{@outcome} for a moved existing worker",
           f do
        message =
          Sandbox.unboxed_run(Repo, fn ->
            f.child.message
            |> Ash.Changeset.for_update(:set_generation_state, %{status: :generating},
              actor: f.actor
            )
            |> Ash.update!(actor: f.actor)
          end)

        worker = generation_worker!(message.id)

        held =
          hold_delete!(
            fn ->
              {root, _notifications} =
                Chat
                |> Ash.Changeset.for_create(:create_empty, %{}, actor: f.actor)
                |> Ash.create!(actor: f.actor, return_notifications?: true)

              message
              |> Ash.Changeset.for_update(:move_to_chat, %{chat_id: root.id, parent_id: nil},
                actor: f.actor
              )
              |> Ash.update!(actor: f.actor, return_notifications?: true)

              Ash.destroy!(root, actor: f.actor, return_notifications?: true)
              root.id
            end,
            f.actor
          )

        Sandbox.unboxed_run(Repo, fn ->
          # This is the false-positive condition of the former deleted-row barrier:
          # the root is absent while the real transaction is still in progress.
          assert_missing!(Chat, held.value, f.actor)
          current = Ash.get!(ChatMessage, message.id, actor: f.actor)
          assert current.chat_id == f.child.chat.id
          assert current.status == :generating
        end)

        probe_worker!(worker)
        refute_receive {:canceled, _}, 0
        release!(held, @outcome, f.actor)

        if @outcome == :commit do
          pid = worker.pid
          assert_receive {:canceled, ^pid}, @timeout
          assert finish!(worker) == :canceled
          Sandbox.unboxed_run(Repo, fn -> assert_missing!(ChatMessage, message.id, f.actor) end)
        else
          probe_worker!(worker)
          refute_receive {:canceled, _}, 0

          Sandbox.unboxed_run(Repo, fn ->
            current = Ash.get!(ChatMessage, message.id, actor: f.actor)
            assert current.chat_id == f.child.chat.id
            assert current.status == :generating
            assert Ash.get!(Chat, f.child.chat.id, actor: f.actor).last_message_id == message.id
            assert Ash.get!(ChatMessageStep, f.child.step.id, actor: f.actor)
          end)
        end
      end

      test "pending child upload staging honors an outer #{@outcome}", f do
        upload = Sandbox.unboxed_run(Repo, fn -> upload!(f.child.chat, f.actor) end)
        :ok = UploadStaging.ensure_scope(:chat)
        path = UploadStaging.chat_upload_path(upload.external_id)
        File.write!(path, "partial")
        on_exit(fn -> File.rm(path) end)

        held =
          hold_delete!(
            fn -> Ash.destroy!(f.source.step, actor: f.actor, return_notifications?: true) end,
            f.actor
          )

        assert File.read!(path) == "partial"
        release!(held, @outcome, f.actor)

        Sandbox.unboxed_run(Repo, fn ->
          if @outcome == :commit do
            assert_missing!(ChatUploadSession, upload.id, f.actor)
            refute File.exists?(path)
          else
            assert Ash.get!(ChatUploadSession, upload.id, actor: f.actor)
            assert File.read!(path) == "partial"
          end
        end)
      end
    end

    test "deletion without runtime work neither captures an xid nor starts a cleanup task", f do
      before_jobs = Task.Supervisor.children(@cleanup_supervisor)

      Sandbox.unboxed_run(Repo, fn -> Ash.destroy!(f.source.step, actor: f.actor) end)

      assert Task.Supervisor.children(@cleanup_supervisor) == before_jobs
      refute_receive {:captured, _, _}, 0
      refute_receive {:outcome, _, _, _, _}, 0
    end
  end

  describe "fence order of source deletion" do
    @describetag :whitebox

    setup do
      fixture =
        Sandbox.unboxed_run(Repo, fn ->
          actor = committed_actor!("cleanup-locks")
          source = fenced_anchor!(actor)
          child = fenced_anchor!(actor, create_linked_chat!(actor, source))
          nested = fenced_anchor!(actor, create_linked_chat!(actor, child))
          sibling_source = fenced_anchor!(actor, source.chat)
          sibling = fenced_anchor!(actor, create_linked_chat!(actor, sibling_source))

          %{
            actor: actor,
            source: source,
            child: child,
            nested: nested,
            sibling: sibling,
            usage: create_usage_record!(actor, nested),
            task: create_fork_task!(actor, source, child.chat)
          }
        end)

      on_exit(fn -> cleanup_committed_owner!(fixture.actor) end)
      attach_query_barrier!()
      fixture
    end

    for {name, root} <- [{"source-step", :step}, {"chat", :chat}] do
      @root root
      test "#{name} cleanup fences nested messages before detaching their usage", f do
        parent = self()
        record = if @root == :step, do: f.source.step, else: f.source.chat
        %{actor: actor, nested: nested, usage: usage} = f

        writer =
          db_task!(fn ->
            pause_after_query(&lock_query?(&1, "chat_messages"), parent)

            Lease.with_token_fence(nested.message.id, nested.message.generation_fence_token, fn ->
              usage
              |> Ash.Changeset.for_update(
                :detach_deleted_references,
                %{step_ids: [nested.step.id]},
                actor: actor
              )
              |> Ash.update!(actor: actor)

              :persisted
            end)
          end)

        assert {:ok, :persisted} = race_cleanup!(writer, record, actor)

        Sandbox.unboxed_run(Repo, fn ->
          retained = Ash.get!(LlmUsageRecord, usage.id, actor: actor)
          assert retained.output_tokens == usage.output_tokens
          assert retained.cost == usage.cost
          assert retained.chat_id == nil
          assert retained.chat_message_id == nil
          assert retained.chat_message_step_id == nil
          assert retained.chat_message_step_id_snapshot == nested.step.id
          assert_missing!(Chat, f.child.chat.id, actor)
          assert_missing!(Chat, nested.chat.id, actor)

          if @root == :step do
            assert Ash.get!(Chat, f.source.chat.id, actor: actor)
            assert Ash.get!(Chat, f.sibling.chat.id, actor: actor)
          else
            assert_missing!(Chat, f.source.chat.id, actor)
          end
        end)
      end
    end

    test "direct child deletion fences the parent task's lifecycle message before its envelope",
         f do
      %{actor: actor, source: source, child: child, task: task} = f
      race_task!(f, child.chat)

      Sandbox.unboxed_run(Repo, fn ->
        retained = Ash.get!(BackgroundTask, task.id, actor: actor)
        assert retained.target_chat_id == nil
        assert retained.source_chat_id == source.chat.id
        assert retained.source_message_id == source.message.id
        assert retained.lifecycle_message_id == source.message.id
        assert_missing!(Chat, child.chat.id, actor)
      end)
    end

    test "source-chat cleanup waits for mark_running before detaching its task", f do
      race_task!(f, f.source.chat)

      Sandbox.unboxed_run(Repo, fn ->
        retained = Ash.get!(BackgroundTask, f.task.id, actor: f.actor)
        assert retained.status == :canceled
        assert retained.source_chat_id == nil
        assert retained.lifecycle_message_id == nil
        assert retained.target_chat_id == nil
      end)
    end

    test "a message-fenced first usage insertion is not blocked by an early chat FK lock", f do
      parent = self()
      %{actor: actor, nested: nested, source: source, usage: usage} = f

      Sandbox.unboxed_run(Repo, fn ->
        LinkedForkCleanupLocksUsageFixture
        |> Ash.get!(usage.id, actor: actor)
        |> Ash.destroy!(actor: actor)
      end)

      writer =
        db_task!(fn ->
          pause_after_query(&lock_query?(&1, "chat_messages"), parent)

          Lease.with_token_fence(nested.message.id, nested.message.generation_fence_token, fn ->
            create_usage_record!(actor, nested)
          end)
        end)

      assert {:ok, %LlmUsageRecord{} = written} = race_cleanup!(writer, source.chat, actor)

      Sandbox.unboxed_run(Repo, fn ->
        retained = Ash.get!(LlmUsageRecord, written.id, actor: actor)
        assert retained.chat_id == nil
        assert retained.chat_message_id == nil
        assert retained.chat_message_step_id == nil
        assert retained.chat_message_step_id_snapshot == nested.step.id
        assert retained.cost == 0.25
      end)
    end

    test "direct message deletion takes its chat fence before the message fence", f do
      parent = self()
      actor = f.actor
      other = Sandbox.unboxed_run(Repo, fn -> fenced_anchor!(actor) end)

      writer =
        db_task!(fn ->
          pause_after_query(&lock_query?(&1, "chats"), parent)

          Lease.with_token_chat_fence(
            other.message.id,
            other.chat.id,
            other.message.generation_fence_token,
            fn -> :persisted end
          )
        end)

      assert {:ok, :persisted} = race_cleanup!(writer, other.message, actor)

      Sandbox.unboxed_run(Repo, fn ->
        assert Ash.get!(Chat, other.chat.id, actor: actor).last_message_id == nil
        assert_missing!(ChatMessage, other.message.id, actor)
      end)
    end

    test "a preflight before a nested retry fence serializes with source deletion", f do
      parent = self()
      %{actor: actor, source: source, child: child} = f

      retry =
        db_task!(fn ->
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
      cleanup = cleanup_task!(source.step, actor)
      assert_receive {:cleanup_backend, cleanup_backend}, @timeout
      assert cleanup_backend != retry_backend
      send(retry.pid, {:continue_after_block, cleanup_backend})

      assert {:ok, {:ok, :ok}} = finish!(retry)
      assert {:ok, :deleted} = finish!(cleanup)
    end

    test "a source-step preflight does not lock an independent sibling fork", f do
      parent = self()
      %{actor: actor, source: source, sibling: sibling} = f

      holder =
        db_task!(fn ->
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
        db_task!(fn ->
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
  end

  describe "fence order of keep-children deletion" do
    @describetag :whitebox

    setup do
      fixture =
        Sandbox.unboxed_run(Repo, fn ->
          actor = committed_actor!("reparent-locks")
          chat = create_empty_chat!(actor)
          parent = fork_anchor!(actor, chat, nil)

          {:ok, deleted} =
            Threads.add_message(chat, :user, "Remove only this message",
              actor: actor,
              parent_id: parent.message.id
            )

          stale_chat = Ash.get!(Chat, chat.id, actor: actor)
          child = fork_anchor!(actor, chat, deleted.id)
          %{actor: actor, chat: stale_chat, parent: parent, deleted: deleted, child: child}
        end)

      on_exit(fn -> cleanup_committed_owner!(fixture.actor) end)
      attach_query_barrier!()
      fixture
    end

    test "a retry prelock blocks deletion before its first reparent or active-leaf mutation", f do
      parent = self()
      %{actor: actor, chat: chat, deleted: deleted, child: child} = f
      before = Sandbox.unboxed_run(Repo, fn -> tree_state!(chat, actor) end)

      retry =
        db_task!(fn ->
          pause_after_query(&chat_fence?/1, parent, fn -> tree_state!(chat, actor) end)
          retry!(f, parent)
        end)

      assert_receive {:query_barrier, retry_pid, retry_backend}, @timeout
      assert retry_pid == retry.pid
      assert_receive {:retry_backend, ^retry_backend}, @timeout
      deletion = keep_children_task!(f, parent)
      assert_receive {:delete_backend, delete_backend}, @timeout
      assert delete_backend != retry_backend
      send(retry.pid, {:continue_after_block, delete_backend})

      assert_receive {:blocked_query, ^retry_pid, ^delete_backend, query, observed}, @timeout
      assert chat_fence?(query)
      assert observed == before
      assert {:ok, replacement_id} = finish!(retry)
      assert is_integer(replacement_id)
      assert {:ok, branch} = finish!(deletion)
      assert Enum.map(branch, & &1.id) == [f.parent.message.id, child.message.id]

      Sandbox.unboxed_run(Repo, fn ->
        assert_deleted_and_reparented!(f)
        assert_missing!(ChatMessageStep, f.parent.step.id, actor)

        assert Ash.get!(ChatMessageStep, replacement_id, actor: actor).chat_message_id ==
                 f.parent.message.id

        assert_missing!(ChatMessage, deleted.id, actor)
      end)
    end

    test "deletion retains its chat fence across reparent until destroy when a retry arrives",
         f do
      parent = self()

      deletion =
        db_task!(fn ->
          pause_after_query(&reparent_update?/1, parent)
          Threads.delete_message_keep_children(f.chat.id, f.deleted.id, f.actor)
        end)

      assert_receive {:query_barrier, delete_pid, delete_backend}, @timeout
      assert delete_pid == deletion.pid
      retry = db_task!(fn -> retry!(f, parent) end)
      assert_receive {:retry_backend, retry_backend}, @timeout
      assert retry_backend != delete_backend
      send(deletion.pid, {:continue_after_block, retry_backend})

      assert_receive {:blocked_query, ^delete_pid, ^retry_backend, query, :ok}, @timeout
      # Waiting on messages here would mean reparent acquired its child/FK locks
      # before the common chat fence, recreating the retry/delete inversion.
      assert chat_fence?(query)
      assert {:ok, branch} = finish!(deletion)
      assert Enum.map(branch, & &1.id) == [f.parent.message.id, f.child.message.id]
      assert {:ok, replacement_id} = finish!(retry)
      assert is_integer(replacement_id)
      Sandbox.unboxed_run(Repo, fn -> assert_deleted_and_reparented!(f) end)
    end

    test "the chat and messages are reread after waiting for the common fence", f do
      %{actor: actor, chat: chat, deleted: deleted, child: child} = f

      change_branch = fn ->
        child.message
        |> Ash.Changeset.for_update(:reparent, %{parent_id: f.parent.message.id}, actor: actor)
        |> Ash.update!(actor: actor)

        chat
        |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: deleted.id},
          actor: actor
        )
        |> Ash.update!(actor: actor)

        :changed_branch
      end

      assert :changed_branch = race_keep_children!(f, change_branch)
      Sandbox.unboxed_run(Repo, fn -> assert_deleted_and_reparented!(f) end)
    end

    test "a new fork on retained history does not invalidate keep-children deletion", f do
      add_fork = fn -> create_linked_chat!(f.actor, f.child).id end
      linked_id = race_keep_children!(f, add_fork)

      Sandbox.unboxed_run(Repo, fn ->
        assert_deleted_and_reparented!(f)
        assert Ash.get!(Chat, linked_id, actor: f.actor).fork_source_step_id == f.child.step.id
      end)
    end

    test "a new dependent of a deleted step still fails closed after waiting", f do
      parent = self()
      %{actor: actor, chat: chat, parent: source} = f
      holder = chat_fence_holder!(chat, actor, fn -> create_linked_chat!(actor, source).id end)
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
  end

  # Holds the chat fence (FOR NO KEY UPDATE) of a keep-children deletion and
  # runs `change` while the deletion waits for it; returns what `change` returned.
  defp race_keep_children!(f, change) do
    parent = self()
    holder = chat_fence_holder!(f.chat, f.actor, change)
    assert_receive {:query_barrier, holder_pid, holder_backend}, @timeout
    assert holder_pid == holder.pid
    deletion = keep_children_task!(f, parent)
    assert_receive {:delete_backend, delete_backend}, @timeout
    assert delete_backend != holder_backend
    send(holder.pid, {:continue_after_block, delete_backend})
    assert_receive {:blocked_query, ^holder_pid, ^delete_backend, _, changed}, @timeout
    assert {:ok, %Chat{}} = finish!(holder)
    assert {:ok, branch} = finish!(deletion)
    assert Enum.map(branch, & &1.id) == [f.parent.message.id, f.child.message.id]
    changed
  end

  defp chat_fence_holder!(chat, actor, change) do
    parent = self()

    db_task!(fn ->
      Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
        pause_after_query(&chat_fence?/1, parent, change)

        Chat
        |> Ash.Query.filter(id == ^chat.id)
        |> Ash.Query.lock("FOR NO KEY UPDATE")
        |> Ash.read_one!(actor: actor)
      end)
    end)
  end

  # `writer` pauses after its first matching lock; source cleanup of `record`
  # must then wait on it. Returns the writer's result.
  defp race_cleanup!(writer, record, actor) do
    assert_receive {:query_barrier, writer_pid, writer_backend}, @timeout
    assert writer_pid == writer.pid
    cleanup = cleanup_task!(record, actor)
    assert_receive {:cleanup_backend, cleanup_backend}, @timeout
    assert cleanup_backend != writer_backend
    send(writer.pid, {:continue_after_block, cleanup_backend})
    assert_receive {:blocked_query, ^writer_pid, ^cleanup_backend, _query, :ok}, @timeout
    result = finish!(writer)
    assert {:ok, :deleted} = finish!(cleanup)
    result
  end

  defp race_task!(f, record) do
    parent = self()
    %{actor: actor, task: task} = f

    task =
      Sandbox.unboxed_run(Repo, fn ->
        task
        |> Ash.Changeset.for_update(:update_state, %{status: :queued}, actor: actor)
        |> Ash.update!(actor: actor)
      end)

    writer =
      db_task!(fn ->
        pause_after_query(&lock_query?(&1, "chat_messages"), parent)
        BackgroundTasks.mark_running(task)
      end)

    assert {:ok, %BackgroundTask{status: :canceled}} = race_cleanup!(writer, record, actor)
  end

  defp cleanup_task!(%resource{} = record, actor) do
    parent = self()

    db_task!(fn ->
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

  defp retry!(f, parent) do
    Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
      send(parent, {:retry_backend, backend_pid!()})

      # Match production's precise preflight and reuse it inside the mutation.
      # No Lease manager RPC or provider is needed for this SQL interleaving.
      LinkedForkCleanup.with_scope({:steps, f.parent.message.id, 1}, f.actor, fn operation ->
        Persistence.replace_steps_for_retry!(
          f.parent.message.id,
          1,
          %{"retry" => true},
          [],
          operation
        )
      end)
    end)
  end

  defp keep_children_task!(f, parent) do
    db_task!(fn ->
      send(parent, {:delete_backend, backend_pid!()})
      Threads.delete_message_keep_children(f.chat.id, f.deleted.id, f.actor)
    end)
  end

  defp chat_fence?(sql), do: lock_query?(sql, "chats", "FOR NO KEY UPDATE")

  defp reparent_update?(sql),
    do: String.starts_with?(sql, ~s(UPDATE "chat_messages")) and sql =~ ~s("parent_id")

  defp tree_state!(chat, actor) do
    messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(actor: actor)

    {Ash.get!(Chat, chat.id, actor: actor).last_message_id,
     Enum.map(messages, &{&1.id, &1.parent_id})}
  end

  defp assert_deleted_and_reparented!(f) do
    %{actor: actor, chat: chat, parent: parent, deleted: deleted, child: child} = f
    assert_missing!(ChatMessage, deleted.id, actor)
    assert Ash.get!(ChatMessage, child.message.id, actor: actor).parent_id == parent.message.id
    assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == child.message.id
  end

  defp committed_actor!(prefix) do
    %{user: actor} = user_fixture(%{username: "#{prefix}-#{Ecto.UUID.generate()}"})
    actor
  end

  defp fenced_anchor!(actor, chat \\ nil) do
    create_tool_call_anchor!(actor,
      chat: chat || create_empty_chat!(actor),
      message: %{generation_fence_token: Ecto.UUID.generate()},
      step: %{response_final: true}
    )
  end

  defp fork_anchor!(actor, chat, parent_id) do
    create_tool_call_anchor!(actor,
      chat: chat,
      message: %{parent_id: parent_id},
      step: %{response_final: true},
      content: %{kind: :opaque, content_json: fork_call_payload()}
    )
  end

  @doc false
  def observe_outcome(_event, _measurements, metadata, parent) do
    case {metadata.query, metadata.result} do
      {"SELECT pg_current_xact_id()::text", {:ok, %{rows: [[xid]]}}} ->
        send(parent, {:captured, self(), xid})

      {"SELECT pg_xact_status($1::text::xid8)", {:ok, %{rows: [[status]]}}} ->
        send(parent, {:outcome, self(), hd(metadata.params), status, Repo.in_transaction?()})

      _ ->
        :ok
    end
  end

  @doc false
  def pause_outcome(_event, _measurements, metadata, {parent, gate}) do
    if self() != parent and metadata.query == "SELECT pg_xact_status($1::text::xid8)" and
         match?({:ok, %{rows: [["in progress"]]}}, metadata.result) do
      send(parent, {:outcome_paused, self(), gate})

      receive do
        {:resume_outcome, ^gate} -> :ok
      after
        @timeout -> flunk("Missing cleanup outcome release")
      end
    end
  end

  defp hold_delete!(fun, actor) do
    parent = self()
    before_jobs = Task.Supervisor.children(@cleanup_supervisor)

    holder =
      supervised_task!(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            %{rows: [[xid, backend]]} =
              Repo.query!("SELECT pg_current_xact_id()::text, pg_backend_pid()")

            value = fun.()
            send(parent, {:deleted, self(), xid, backend, value})

            receive do
              :commit -> :deleted
              :abort -> Repo.rollback(:keep_source)
            after
              @timeout -> flunk("Missing outer transaction decision")
            end
          end)
        end)
      end)

    holder_pid = holder.pid
    assert_receive {:deleted, ^holder_pid, xid, backend, value}, @timeout
    assert_receive {:captured, ^holder_pid, ^xid}, @timeout
    refute_receive {:captured, ^holder_pid, _}, 0
    [job] = Task.Supervisor.children(@cleanup_supervisor) -- before_jobs
    monitor = Process.monitor(job)
    assert_receive {:outcome, ^job, ^xid, "in progress", false}, @timeout

    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[observer_backend]]} = Repo.query!("SELECT pg_backend_pid()")
      refute backend == observer_backend
      assert TransactionOutcome.status!(xid, actor) == :in_progress
    end)

    %{holder: holder, job: job, monitor: monitor, xid: xid, value: value}
  end

  defp release!(held, outcome, actor) do
    send(held.holder.pid, outcome)
    expected = if outcome == :commit, do: {:ok, :deleted}, else: {:error, :keep_source}
    assert finish!(held.holder) == expected
    %{job: job, monitor: monitor} = held
    assert_receive {:DOWN, ^monitor, :process, ^job, :normal}, @timeout

    Sandbox.unboxed_run(Repo, fn ->
      expected = if outcome == :commit, do: :committed, else: :aborted
      assert TransactionOutcome.status!(held.xid, actor) == expected
      assert TransactionOutcome.await_committed?(held.xid, actor) == (outcome == :commit)
    end)
  end

  defp generation_worker!(message_id) do
    parent = self()

    worker =
      supervised_task!(fn ->
        {:ok, _} =
          Registry.register(IntellectualClub.Generation.Registry, {:message, message_id}, %{})

        send(parent, {:ready, self()})
        receive_generation_cancel!(parent)
      end)

    pid = worker.pid
    assert_receive {:ready, ^pid}, @timeout
    worker
  end

  defp receive_generation_cancel!(parent) do
    receive do
      {:probe, ref} ->
        send(parent, {:worker_ready, self(), ref})
        receive_generation_cancel!(parent)

      {:"$gen_cast", :cancel} ->
        send(parent, {:canceled, self()})
        :canceled
    end
  end

  defp probe_worker!(%{pid: pid}) do
    ref = make_ref()
    send(pid, {:probe, ref})
    assert_receive {:worker_ready, ^pid, ^ref}, @timeout
  end

  defp background_worker!(task, fixture) do
    parent = self()

    worker =
      supervised_task!(fn ->
        {:ok, _} =
          Registry.register(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id, %{})

        send(parent, {:ready, self()})
        receive_background_cancel!(parent, task, fixture)
      end)

    pid = worker.pid
    assert_receive {:ready, ^pid}, @timeout
    worker
  end

  defp receive_background_cancel!(parent, task, %{actor: actor, source: source} = fixture) do
    receive do
      {:probe, ref} ->
        send(parent, {:worker_ready, self(), ref})
        receive_background_cancel!(parent, task, fixture)

      {:"$gen_call", from, :cancel} ->
        Sandbox.unboxed_run(Repo, fn ->
          # This independent connection must be able to lock both the surviving
          # authorities and the envelope while the cleanup caller awaits this RPC.
          assert {:ok, current} =
                   Repo.transaction(fn ->
                     for {resource, id} <- [
                           {Chat, source.chat.id},
                           {ChatMessage, source.message.id},
                           {BackgroundTask, task.id}
                         ] do
                       resource
                       |> Ash.Query.filter(id == ^id)
                       |> Ash.Query.lock("FOR UPDATE NOWAIT")
                       |> Ash.read_one!(actor: actor)
                     end

                     Ash.get!(BackgroundTask, task.id, actor: actor)
                   end)

          send(parent, {:cancel_state, self(), current})
          assert {:ok, _} = BackgroundTasks.mark_canceled(current)
        end)

        GenServer.reply(from, :ok)
        :canceled
    end
  end

  defp upload!(chat, actor) do
    ChatUploadSession
    |> Ash.Changeset.for_create(
      :start,
      %{
        chat_id: chat.id,
        filename: "pending.bin",
        mime_type: "application/octet-stream",
        size_bytes: 10,
        chunk_size_bytes: 10,
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp await_cleanup_jobs! do
    @cleanup_supervisor
    |> Task.Supervisor.children()
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, @timeout
      assert reason in [:normal, :noproc]
    end)
  end
end
