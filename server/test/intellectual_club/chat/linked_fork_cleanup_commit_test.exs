defmodule IntellectualClub.Chat.LinkedForkCleanupCommitTest do
  use ExUnit.Case, async: false

  import IntellectualClub.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatUploadSession
  alias IntellectualClub.Chat.LinkedForkCleanup.TransactionOutcome
  alias IntellectualClub.Chat.LinkedForkCleanupLocksTaskFixture
  alias IntellectualClub.Chat.LinkedForkCleanupLocksUsageFixture
  alias IntellectualClub.Files.UploadStaging
  alias IntellectualClub.Repo

  require Ash.Query

  @timeout 10_000
  @cleanup_supervisor IntellectualClub.BackgroundTasks.ExecutionSupervisor

  setup do
    # Serial, real-commit tests: detached production tasks need their own normal
    # connections, not an inherited/shared Sandbox transaction or an allowance.
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        %{user: actor} = user_fixture(%{username: "cleanup-commit-#{Ecto.UUID.generate()}"})
        source = anchor!(actor)
        child = anchor!(actor, linked_chat!(source, actor))
        %{actor: actor, source: source, child: child}
      end)

    on_exit(fn ->
      await_cleanup_jobs!()
      cleanup_fixture!(fixture.actor)
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
    nested = Sandbox.unboxed_run(Repo, fn -> anchor!(f.actor, linked_chat!(f.child, f.actor)) end)
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
        ChatMessage
        |> Ash.Changeset.for_create(
          :add_message,
          %{
            chat_id: f.source.chat.id,
            parent_id: f.source.message.id,
            role: :assistant,
            status: :generating
          },
          actor: f.actor
        )
        |> Ash.create!(actor: f.actor)
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
    task = Sandbox.unboxed_run(Repo, fn -> background_task!(f.source, f.child.chat, f.actor) end)
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
    task = Sandbox.unboxed_run(Repo, fn -> background_task!(f.source, f.child.chat, f.actor) end)
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

  defp supervised_task!(fun) do
    parent = self()
    result_ref = make_ref()

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(parent, {:task_result, result_ref, fun.()})
           end},
          id: result_ref
        )
      )

    %{pid: pid, monitor: Process.monitor(pid), result_ref: result_ref}
  end

  defp finish!(%{pid: pid, monitor: monitor, result_ref: result_ref}) do
    assert_receive {:task_result, ^result_ref, result}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @timeout
    result
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

  defp anchor!(actor, chat \\ nil) do
    chat = chat || create_chat!(actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{chat_id: chat.id, role: :assistant, status: :done},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(:create, %{chat_message_id: message.id, sequence: 1},
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
      fork_task: "Real outer transaction regression fixture"
    })
    |> Ash.create!(actor: actor)
  end

  defp background_task!(source, target, actor) do
    BackgroundTask
    |> Ash.Changeset.for_create(
      :create,
      %{
        kind: "fork",
        adapter: "cleanup_commit_test",
        function_name: "fork",
        status: :running,
        source_chat_id: source.chat.id,
        source_message_id: source.message.id,
        lifecycle_message_id: source.message.id,
        source_step_id: source.step.id,
        source_tool_call_item_id: source.item.id,
        target_chat_id: target.id,
        runner_ref: %{"original_target" => target.id}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
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

  defp assert_missing!(resource, id, actor) do
    assert {:ok, nil} = resource |> Ash.Query.filter(id == ^id) |> Ash.read_one(actor: actor)
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
