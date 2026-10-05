defmodule IntellectualClub.Generation.WorkerPersistenceTest do
  @moduledoc """
  Worker persistence runs in writer tasks. Telemetry barriers hold a writer
  before (`:start`) or after (`:stop`) its transaction to check what the Worker
  may and may not do while the outcome is unknown.
  """
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Test.GenerationRuntime

  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.SubchatCostCache
  alias IntellectualClub.Generation.{Lease, Persistence, QueueCoordinator}
  alias IntellectualClub.Generation.{StepRequests, Worker}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.SandboxCleanup
  alias IntellectualClub.Test.GenerationRuntime.Barrier
  alias IntellectualClubWeb.Bff.{ChatPollPayload, PollCache}

  @repo_query [:intellectual_club, :repo, :query]
  @persistence_start [:intellectual_club, :generation, :persistence, :start]
  @persistence_stop [:intellectual_club, :generation, :persistence, :stop]

  setup do
    unless Process.whereis(IntellectualClub.Generation.PersistenceTasks) do
      start_supervised!({Task.Supervisor, name: IntellectualClub.Generation.PersistenceTasks})
    end

    for child <- [PollCache, SubchatCostCache] do
      unless Process.whereis(child), do: start_supervised!(child)
    end

    :ok
  end

  describe "commit ordering" do
    test "blocked initialization stays publicly generating until provider dispatch" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, initialize: :start, initialize: :stop)
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      epoch = Worker.poll(worker, %{}, protocol: :cursor).stream.cursor["epoch"]
      assert is_binary(epoch)

      for stage <- [:start, :stop] do
        writer = Barrier.await_persistence(:initialize, stage)
        state = :sys.get_state(worker)
        assert state.status == :initializing
        assert state.phase == :persisting
        assert state.stream_task == nil
        assert state.tool_task == nil

        assert Worker.get_current_state(worker) == %{
                 status: :generating,
                 phase: :persisting,
                 step: nil
               }

        assert Worker.poll(worker, %{}) == Worker.get_current_state(worker)
        assert {:ok, snapshot} = GenerationSupervisor.poll_generation(fixture.message.id)
        assert %{status: :generating, phase: :persisting, step: nil} = snapshot

        assert {:ok, payload} =
                 ChatPollPayload.response(
                   fixture.message,
                   fixture.actor,
                   {:ok, snapshot},
                   %{},
                   %{}
                 )

        assert payload.status == "generating"
        assert payload.phase == "persisting"
        assert payload.availability == "ready"
        assert payload.poll_after_ms == 1750
        assert payload.finished_at == nil
        assert payload.error_detail == nil
        assert message!(fixture).status == :generating
        refute_provider_started(fixture)
        refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
        Barrier.release(writer)
      end

      await_provider!(fixture)
      _ = :sys.get_state(worker)
      assert {:ok, snapshot} = GenerationSupervisor.poll_generation(fixture.message.id)
      assert snapshot.status == :generating
      assert snapshot.phase == :provider
      assert Worker.poll(worker, %{}, protocol: :cursor).stream.cursor["epoch"] == epoch
      cancel_worker!(worker)
    end

    test "provider and tool dispatch never query the database in the worker" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, initialize: :stop)
      worker = start_worker!(fixture)
      writer = Barrier.await_persistence(:initialize, :stop)
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          @repo_query,
          &__MODULE__.observe_worker_query/4,
          {self(), worker}
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      Barrier.release(writer)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :tools})
      await_provider!(fixture)
      _ = :sys.get_state(worker)
      assert Persistence.list_missing_tool_calls!(fixture.step_id) == []
      refute_receive {:worker_query, ^worker, _query}, 0
      cancel_worker!(worker)
    end

    test "slow commit leaves snapshots readable and cancel suppresses deferred steering and tools" do
      fixture = generation_fixture!()

      Barrier.gate_persistence(fixture.message.id,
        provider_completed: :start,
        provider_completed: :stop,
        cancel: :start
      )

      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :tools})
      writer = Barrier.await_persistence(:provider_completed, :start)

      state = :sys.get_state(worker)
      ref = state.persistence_op.task.ref
      assert state.persistence_op.task.pid == writer.pid
      assert state.tool_task == nil
      assert state.phase == :persisting

      # Persistence is blocked, but the Worker still serves on-demand UI reads.
      assert {:ok, snapshot} = GenerationSupervisor.poll_generation(fixture.message.id)
      assert snapshot.phase == :persisting
      assert snapshot.status == :generating
      refute Map.has_key?(snapshot, :context)
      refute Map.has_key?(snapshot.step, :raw_request)
      refute Map.has_key?(snapshot.step, :raw_response)
      refute inspect(snapshot) =~ "large_raw_only"

      queued = enqueue_steer!(fixture, "must not reach tools", worker)
      assert queued.status == :pending
      cancel_ref = command(worker, :cancel_and_wait)
      state = :sys.get_state(worker)
      assert state.cancel_requested?
      assert state.persistence_op.identity == writer.identity
      refute_receive {^cancel_ref, _reply}, 0

      Barrier.release(writer)
      committed = Barrier.await_persistence(:provider_completed, :stop)
      assert committed.identity == writer.identity
      assert step!(fixture).status == :waiting_tools
      assert usage!(fixture).output_tokens == 3
      assert :sys.get_state(worker).tool_task == nil

      # The runtime status still precedes the committed step until the writer ACK.
      snapshot = Worker.poll(worker, %{}, protocol: :cursor)
      assert snapshot.step.status == "waiting_provider"
      message = message!(fixture, [:poll_revision])

      assert {:ok, canonical} =
               ChatPollPayload.cursor_response(
                 message,
                 fixture.actor,
                 {:ok, snapshot},
                 %{"working_step_id" => "latest"},
                 %{}
               )

      assert canonical.runtime_cursor["retired"]
      assert is_map(canonical.content)
      assert canonical.working_open.step.items != []
      assert Enum.all?(canonical.working_open.step.items, &(&1.id > 0))
      retired = Worker.poll(worker, canonical.runtime_cursor, protocol: :cursor)
      assert retired.step == nil
      refute retired.stream.reset

      params = %{
        "working_step_id" => "latest",
        "content_revision" => canonical.content_revision,
        "view_revision" => canonical.view_revision,
        "revision" => canonical.revision
      }

      assert :unchanged ==
               ChatPollPayload.cursor_response(
                 message,
                 fixture.actor,
                 {:ok, retired},
                 params,
                 %{}
               )

      Barrier.release(committed)
      cancel = Barrier.await_persistence(:cancel, :start)

      # A late acknowledgment cannot replace the current cancellation operation.
      send(worker, {ref, {:persistence_result, writer.identity, {:ok, :stale}}})
      state = :sys.get_state(worker)
      assert state.persistence_op.identity == cancel.identity
      assert state.tool_task == nil
      assert state.stream_task == nil
      Barrier.release(cancel)
      assert_receive {^cancel_ref, :ok}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert message!(fixture).status == :canceled
      assert usage!(fixture).output_tokens == 3
      assert GenerationSupervisor.poll_generation(fixture.message.id) == :not_found
      refute_provider_started(fixture)
    end

    test "tools and the next provider request wait for committed acknowledgments" do
      fixture = generation_fixture!()

      Barrier.gate_persistence(fixture.message.id,
        provider_completed: :stop,
        tool_followup: :start,
        tool_followup: :stop
      )

      worker = start_worker!(fixture)
      {provider, original} = await_provider!(fixture)
      old_stream_ref = :sys.get_state(worker).stream_ref
      send(provider, {:complete, :tools})
      writer = Barrier.await_persistence(:provider_completed, :stop)
      assert length(Persistence.list_missing_tool_calls!(fixture.step_id)) == 1
      assert :sys.get_state(worker).tool_task == nil

      queued = enqueue_steer!(fixture, "serialized instruction", worker)
      Barrier.release(writer)

      writer = Barrier.await_persistence(:tool_followup, :start)
      assert Persistence.list_missing_tool_calls!(fixture.step_id) == []
      assert length(Persistence.load_step_for_followup!(fixture.step_id).results) == 1
      assert :sys.get_state(worker).stream_task == nil
      refute_provider_started(fixture)
      Barrier.release(writer)
      writer = Barrier.await_persistence(:tool_followup, :stop)
      [old_step, next_step] = steps!(fixture)
      assert old_step.status == :done
      assert next_step.status == :waiting_provider

      # Steering that arrived during the tools phase joins the follow-up request once.
      assert {:ok, %{status: :delivered, steering_item_id: steering_item_id}} =
               QueuedMessages.get(queued.id, fixture.actor)

      assert is_integer(steering_item_id)
      assert :sys.get_state(worker).stream_task == nil

      send(worker, {:provider_event, old_stream_ref, {:response_complete, %{raw_response: %{}}}})
      _ = :sys.get_state(worker)
      Barrier.release(writer)
      {_provider, next_request} = await_provider!(fixture)

      assert Enum.count(next_request["messages"], &(&1["content"] == "serialized instruction")) ==
               1

      assert StepRequests.request_for_step!(old_step.id, actor: fixture.actor) == original
      assert StepRequests.request_for_step!(next_step.id, actor: fixture.actor) == next_request
      assert length(Persistence.load_step_for_followup!(fixture.step_id).results) == 1
      cancel_worker!(worker)
    end

    test "runtime polling keeps no eagerly serialized snapshot" do
      fixture = generation_fixture!()
      worker = start_worker!(fixture)
      await_provider!(fixture)
      before = :sys.get_state(worker)
      refute Map.has_key?(before, :snapshot_identity)
      first = Worker.poll(worker, %{}, protocol: :cursor)
      second = Worker.poll(worker, first.stream.cursor, protocol: :cursor)
      refute second.stream.reset
      assert second.stream.cursor == first.stream.cursor
      assert :sys.get_state(worker).runtime_epoch == before.runtime_epoch
      cancel_worker!(worker)
    end
  end

  describe "cancellation" do
    test "external cancellation permits late dispatch until validation but cannot revive the message" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, queued_steers: :stop)
      assert {:ok, lease} = Lease.acquire(fixture.message.id)
      worker = start_worker!(fixture, [], %{lease: lease, lease_owner: self()})
      monitor = Process.monitor(worker)
      writer = Barrier.await_persistence(:queued_steers, :stop)
      assert :ok = :sys.suspend(lease.manager)

      try do
        assert :canceled = QueueCoordinator.cancel_generation(fixture.message.id)
        assert Lease.dispatch_allowed?(lease)
        refute Lease.valid?(lease)
        Barrier.release(writer)
        {provider, _request} = await_provider!(fixture)
        provider_monitor = Process.monitor(provider)
        assert Worker.get_current_state(worker).phase == :provider

        assert :ok = :sys.resume(lease.manager)
        Lease.trigger_validation()
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
        assert_receive {:DOWN, ^provider_monitor, :process, ^provider, _reason}, 5_000
        refute Lease.dispatch_allowed?(lease)
        message = message!(fixture)
        assert message.status == :canceled
        assert message.generation_fence_token == nil
        assert step!(fixture).status == :canceled
        assert length(steps!(fixture)) == 1
      after
        :sys.resume(lease.manager)
      end
    end

    test "cancel during retry publication cancels the receiving step without starting another request" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, auto_retry: :stop)
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      {provider, original} = await_provider!(fixture)
      send(provider, :retry)
      writer = Barrier.await_persistence(:auto_retry, :stop)
      [old_step, next_step] = steps!(fixture)
      assert old_step.status == :error
      assert next_step.status == :waiting_provider
      cancel_ref = command(worker, :cancel_and_wait)
      assert :sys.get_state(worker).cancel_requested?
      Barrier.release(writer)
      assert_receive {^cancel_ref, :ok}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert step!(fixture, next_step.id).status == :canceled
      assert StepRequests.request_for_step!(old_step.id, actor: fixture.actor) == original
      refute_provider_started(fixture)
    end

    test "pending cancellation reconciles a committed retry when its acknowledgment is lost" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, auto_retry: :stop, failure_resolution: :start)
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, :retry)
      writer = Barrier.await_persistence(:auto_retry, :stop)
      [old_step, next_step] = steps!(fixture)
      cancel_ref = command(worker, :cancel_and_wait)
      assert :sys.get_state(worker).cancel_requested?
      Barrier.crash(writer)
      resolution = Barrier.await_persistence(:failure_resolution, :start)
      refute_receive {^cancel_ref, _reply}, 0
      Barrier.release(resolution)
      assert_receive {^cancel_ref, :ok}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert step!(fixture, old_step.id).status == :error
      assert step!(fixture, next_step.id).status == :canceled
      refute_provider_started(fixture)
    end

    test "fence validation after cancellation commit preserves its acknowledged cancel result" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, cancel: :stop)
      {:ok, lease} = Lease.acquire(fixture.message.id)
      worker = start_worker!(fixture, [], %{lease: lease, lease_owner: self()})
      monitor = Process.monitor(worker)
      await_provider!(fixture)
      cancel_ref = command(worker, :cancel_and_wait)
      writer = Barrier.await_persistence(:cancel, :stop)
      writer_monitor = Process.monitor(writer.pid)
      assert message!(fixture).status == :canceled

      Lease.trigger_validation()
      _ = :sys.get_state(lease.manager)
      assert :sys.get_state(worker).lease_lost?
      refute_receive {^cancel_ref, _reply}, 0
      refute_receive {:DOWN, ^writer_monitor, :process, _writer, _}, 0
      Barrier.release(writer)
      assert_receive {^cancel_ref, :ok}, 5_000
      assert_receive {:DOWN, ^writer_monitor, :process, _writer, :normal}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      message = message!(fixture)
      assert message.status == :canceled
      assert message.generation_fence_token == nil
      refute_provider_started(fixture)
    end

    test "lease remains owned until the in-flight write and cancellation resolve" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, provider_completed: :stop, cancel: :start)
      {:ok, lease} = Lease.acquire(fixture.message.id)
      worker = start_worker!(fixture, [], %{lease: lease, lease_owner: self()})
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :answer})
      writer = Barrier.await_persistence(:provider_completed, :stop)
      assert writer.identity.lease_ref == lease.ref
      assert writer.identity.fence_token == lease.fence_token
      cancel_ref = command(worker, :cancel_and_wait)
      assert :sys.get_state(worker).cancel_requested?
      assert Lease.acquire(fixture.message.id) == {:error, :already_running}
      Barrier.release(writer)
      writer = Barrier.await_persistence(:cancel, :start)
      assert Lease.acquire(fixture.message.id) == {:error, :already_running}
      monitor = Process.monitor(worker)
      Barrier.release(writer)
      assert_receive {^cancel_ref, :ok}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      {:ok, replacement} = Lease.reserve(fixture.message.id)
      assert replacement.ref != lease.ref
      assert :ok = Lease.release(replacement)
    end

    test "cancel received during a terminal commit cannot roll back a completed generation" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, done: :stop)
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :answer})
      writer = Barrier.await_persistence(:done, :stop)
      cancel_ref = command(worker, :cancel_and_wait)
      assert :sys.get_state(worker).cancel_requested?
      Barrier.release(writer)
      assert_receive {^cancel_ref, {:error, :generation_not_active}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert message!(fixture).status == :done
    end

    test "cancel interrupts an external tool but drains its sibling SQL transaction before releasing the lease" do
      fixture = generation_fixture!()
      tasks = start_supervised!({Task.Supervisor, []})
      test = self()

      context =
        Map.merge(fixture.context, %{
          tool_instances_by_alias: %{"web" => web_search_tool!(fn _, _ -> {:wait, test} end)},
          test_tool_calls: [
            %{name: "missing__run", args: %{}},
            %{name: "web__web_search", args: %{"query" => "cancel while another tool writes"}}
          ]
        })

      manager = Process.whereis(Lease)
      manager_monitor = Process.monitor(manager)
      assert {:ok, _context} = GenerationSupervisor.start_prepared_context(context)
      worker = GenerationSupervisor.generation_worker_pid(fixture.message.id)
      worker_monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)

      # Hold the in-process tool's row-locking SQL while the web tool waits.
      Barrier.attach(@repo_query, fn _event, _measurements, %{query: query} ->
        callers = List.wrap(Process.get(:"$callers"))

        worker in callers and List.first(callers) != worker and
          String.contains?(query, "FOR NO KEY UPDATE") and :tool_sql
      end)

      send(provider, {:complete, :tools})
      writer = Barrier.await(:tool_sql)
      assert_receive {:waiting, request}, 5_000
      writer_monitor = Process.monitor(writer.pid)

      {external, _phase} =
        Enum.find(:sys.get_state(worker).tool_executions, fn {_pid, {_ref, phase}} ->
          phase == :interruptible
        end)

      external_monitor = Process.monitor(external)
      trace_receives!(worker)

      try do
        cancel = Task.Supervisor.async_nolink(tasks, fn -> Worker.cancel_and_wait(worker) end)
        assert_receive {:trace, ^worker, :receive, {:"$gen_call", _, :cancel_and_wait}}, 5_000
        state = :sys.get_state(worker)
        assert state.cancel_requested?
        refute is_nil(state.tool_task)
        assert Task.yield(cancel, 0) == nil
        assert_receive {:DOWN, ^external_monitor, :process, ^external, :killed}, 5_000
        refute_received {:DOWN, ^writer_monitor, :process, _writer, _}
        Barrier.release(writer)

        assert :ok = Task.await(cancel, 5_000)
        assert_receive {:DOWN, ^writer_monitor, :process, _writer, :normal}, 5_000
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 5_000
        assert :ok = SandboxCleanup.stop_background_tasks!()
        assert Process.whereis(Lease) == manager
        refute_received {:DOWN, ^manager_monitor, :process, ^manager, _}
        canceled = message!(fixture)
        assert canceled.status == :canceled
        assert canceled.generation_fence_token == nil
        assert [_missing_external_call] = Persistence.list_missing_tool_calls!(fixture.step_id)
        assert [_saved_result] = Persistence.load_step_for_followup!(fixture.step_id).results
        refute_provider_started(fixture)
      after
        send(request, :continue)
        Process.demonitor(manager_monitor, [:flush])
      end
    end

    test "drain preserves SQL ownership through an active writer and the original lease cleanup ACK" do
      fixture = generation_fixture!()
      message_id = fixture.message.id
      manager = Process.whereis(Lease)
      manager_monitor = Process.monitor(manager)
      tasks = start_supervised!({Task.Supervisor, []})

      # Holding an actual Ash transaction reproduces a borrower being interrupted
      # while it owns the shared connection, not merely a task waiting outside SQL.
      Barrier.attach(
        @persistence_start,
        fn _event, _measurements, meta ->
          meta[:kind] == :initialize and meta[:message_id] == message_id and :writer
        end,
        around: fn wait ->
          Ash.transaction(IntellectualClub.Chat.ChatMessage, fn ->
            Ash.get!(IntellectualClub.Chat.ChatMessage, message_id, authorize?: false)
            wait.()
          end)
        end
      )

      Barrier.attach(@repo_query, fn _event, _measurements, %{query: query} ->
        manager in List.wrap(Process.get(:"$callers")) and
          String.contains?(query, "FOR NO KEY UPDATE") and :lease_cleanup
      end)

      assert {:ok, _context} = GenerationSupervisor.start_prepared_context(fixture.context)
      worker = GenerationSupervisor.generation_worker_pid(message_id)
      writer = Barrier.await(:writer)
      writer_monitor = Process.monitor(writer.pid)
      trace_receives!(worker)

      try do
        drain = Task.Supervisor.async_nolink(tasks, &SandboxCleanup.stop_background_tasks!/0)

        assert_receive {:trace, ^worker, :receive, {:"$gen_cast", :cancel}}, 5_000
        state = :sys.get_state(worker)
        assert state.cancel_requested?
        assert state.persistence_op.task.pid == writer.pid
        assert Task.yield(drain, 0) == nil
        Barrier.release(writer)

        cleanup = Barrier.await(:lease_cleanup)
        state = :sys.get_state(manager)
        assert map_size(state.cleanups) == 1
        assert Map.has_key?(state.leases, message_id)
        assert {:error, :already_running} = Lease.reserve(message_id)
        assert Task.yield(drain, 0) == nil
        Barrier.release(cleanup)

        assert :ok = Task.await(drain, 5_000)
        assert_receive {:DOWN, ^writer_monitor, :process, _writer, :normal}, 5_000
        assert Process.whereis(Lease) == manager
        assert %{leases: leases, cleanups: cleanups} = :sys.get_state(manager)
        assert leases == %{} and cleanups == %{}
        refute_received {:DOWN, ^manager_monitor, :process, ^manager, _}
        assert message!(fixture).generation_fence_token == nil
      after
        Process.demonitor(manager_monitor, [:flush])
      end
    end
  end

  describe "partial runtime output" do
    for {name, terminal, status} <- [
          {"Worker.cancel/1", :worker_cancel, :canceled},
          {"GenerationSupervisor.cancel_generation/1", :supervisor_cancel, :canceled},
          {"a terminal stream error", :stream_error, :error}
        ] do
      @tag terminal: terminal, status: status
      test "#{name} preserves partial runtime output", %{terminal: terminal, status: status} do
        fixture = generation_fixture!()
        message_id = fixture.message.id

        tail =
          if terminal == :stream_error do
            [
              {:error,
               %{
                 retryable: false,
                 error_kind: "provider",
                 status_code: 400,
                 error_text: "Stream failed",
                 raw_response: %{"id" => "partial-error"},
                 usage: %{input_tokens: 30, output_tokens: 7}
               }}
            ]
          else
            [:await]
          end

        fixture =
          with_context(fixture,
            test_script: [
              {:text, :reasoning, "Partial reasoning"},
              {:text, :answer, "Partial answer"},
              {:notify, {:partial_output_ready, message_id}} | tail
            ]
          )

        worker = start_worker!(fixture)
        monitor = Process.monitor(worker)
        assert_receive {:partial_output_ready, ^message_id}, 5_000

        if terminal != :stream_error do
          assert %{step: %{items: [_reasoning, _answer]}} = Worker.get_current_state(worker)
        end

        case terminal do
          :worker_cancel -> Worker.cancel(worker)
          :supervisor_cancel -> assert :ok = GenerationSupervisor.cancel_generation(message_id)
          :stream_error -> :ok
        end

        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
        message = message!(fixture, steps: [:raw_response, items: [:contents]])
        assert message.status == status
        assert message.token_count > 0
        assert message.generation_fence_token == nil
        assert [step] = message.steps
        assert step.status == status
        assert item_text(Enum.find(step.items, &(&1.type == :reasoning))) == "Partial reasoning"
        assert item_text(Enum.find(step.items, &(&1.type == :answer))) == "Partial answer"

        if terminal == :stream_error do
          assert step.raw_response == %{"id" => "partial-error"}
          assert step.input_tokens == 30
          assert step.output_tokens == 7
          assert item_text(Enum.find(step.items, &(&1.type == :error))) == "Stream failed"
        end
      end
    end
  end

  describe "writer crashes and fence loss" do
    for {stage, mode, durable_status} <- [
          {:start, :steered_waiting_provider, :waiting_provider},
          {:stop, :finalize_completed_step, :done}
        ] do
      @tag stage: stage, mode: mode, durable_status: durable_status
      test "a crash at provider commit #{stage} recovers from durable state without replaying the response",
           %{stage: stage, mode: mode, durable_status: durable_status} do
        fixture = generation_fixture!()
        handler = Barrier.gate_persistence(fixture.message.id, provider_completed: stage)
        worker = start_worker!(fixture)
        monitor = Process.monitor(worker)
        {provider, _request} = await_provider!(fixture)
        send(provider, {:complete, :answer})
        Barrier.crash(Barrier.await_persistence(:provider_completed, stage))
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
        assert GenerationSupervisor.poll_generation(fixture.message.id) == :not_found
        assert message!(fixture).status == :generating
        Barrier.detach(handler)

        assert step!(fixture).status == durable_status
        Barrier.gate_persistence(fixture.message.id, done: :stop)
        recovered = start_worker!(fixture, initial_resume_mode: mode)
        recovered_monitor = Process.monitor(recovered)

        if stage == :start do
          {provider, _request} = await_provider!(fixture)
          send(provider, {:complete, :answer})
        end

        Barrier.release(Barrier.await_persistence(:done, :stop))
        assert_receive {:DOWN, ^recovered_monitor, :process, ^recovered, :normal}, 5_000
        assert message!(fixture).status == :done
        assert usage!(fixture).output_tokens == 3
        assert length(steps!(fixture)) == 1
        refute_provider_started(fixture)
      end
    end

    test "worker kill also kills its blocked writer and removes the snapshot owner" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, provider_completed: :start)
      worker = start_worker!(fixture)
      worker_monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :answer})
      writer = Barrier.await_persistence(:provider_completed, :start)
      writer_monitor = Process.monitor(writer.pid)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 5_000
      assert_receive {:DOWN, ^writer_monitor, :process, _writer, :killed}, 5_000
      assert GenerationSupervisor.poll_generation(fixture.message.id) == :not_found
      assert step!(fixture).status == :waiting_provider
    end

    test "fence loss drains a committed intermediate writer without dispatching its tools" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, provider_completed: :stop)
      {:ok, lease} = Lease.acquire(fixture.message.id)
      worker = start_worker!(fixture, [], %{lease: lease, lease_owner: self()})
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :tools})
      writer = Barrier.await_persistence(:provider_completed, :stop)
      writer_monitor = Process.monitor(writer.pid)

      current = message!(fixture)
      assert current.generation_fence_token == lease.fence_token

      current
      |> Ash.Changeset.for_update(:set_generation_fence, %{generation_fence_token: nil},
        actor: fixture.actor
      )
      |> Ash.update!(actor: fixture.actor)

      assert message!(fixture).generation_fence_token == nil
      Lease.trigger_validation()
      _ = :sys.get_state(lease.manager)
      state = :sys.get_state(worker)
      assert state.lease_lost?
      assert state.persistence_op.task.pid == writer.pid
      assert state.tool_task == nil
      refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
      refute_receive {:DOWN, ^writer_monitor, :process, _writer, _}, 0
      Worker.queue_changed(worker)
      send(worker, :consume_queued_steers)
      assert :sys.get_state(worker).persistence_op.task.pid == writer.pid

      Barrier.release(writer)
      assert_receive {:DOWN, ^writer_monitor, :process, _writer, :normal}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert message!(fixture).status == :generating
      assert length(Persistence.list_missing_tool_calls!(fixture.step_id)) == 1
      assert Persistence.load_step_for_followup!(fixture.step_id).results == []
      refute_provider_started(fixture)
      assert {:ok, replacement} = Lease.reserve(fixture.message.id)
      assert :ok = Lease.release(replacement)
    end

    test "a replacement fence rejects the blocked old writer without clearing the successor token" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, provider_completed: :start)
      {:ok, lease} = Lease.acquire(fixture.message.id)
      worker = start_worker!(fixture, [], %{lease: lease, lease_owner: self()})
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :answer})
      writer = Barrier.await_persistence(:provider_completed, :start)

      :sys.replace_state(worker, fn state ->
        :ok = Lease.release(state.lease)
        state
      end)

      {:ok, successor} = Lease.acquire(fixture.message.id)

      try do
        Barrier.release(writer)
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
        assert step!(fixture).status == :waiting_provider
        assert message!(fixture).generation_fence_token == successor.fence_token
        assert Lease.valid?(successor)
      after
        Lease.release(successor)
      end
    end

    test "a committed round transition reconciles in place after writer failure and ignores its late result" do
      fixture = generation_fixture!()
      handler = Barrier.gate_persistence(fixture.message.id, tool_followup: :stop)
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :tools})
      writer = Barrier.await_persistence(:tool_followup, :stop)
      ref = :sys.get_state(worker).persistence_op.task.ref
      [old_step, next_step] = steps!(fixture)
      request = StepRequests.request_for_step!(next_step.id, actor: fixture.actor)
      Barrier.detach(handler)
      Barrier.crash(writer)

      assert {_provider, ^request} = await_provider!(fixture)
      refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
      assert old_step.status == :done
      assert next_step.status == :waiting_provider
      assert :sys.get_state(worker).runtime_step.id == next_step.id

      send(worker, {ref, {:persistence_result, writer.identity, {:ok, :stale}}})
      assert :sys.get_state(worker).runtime_step.id == next_step.id
      assert length(Persistence.load_step_for_followup!(old_step.id).results) == 1
      assert message!(fixture, [:generation_recovery]).generation_recovery == nil
      cancel_worker!(worker)
    end

    test "a late tool result cannot mutate a completed parent with the same live fence" do
      fixture = generation_fixture!()
      test = self()
      tool = web_search_tool!(fn _path, _payload -> {:wait, test} end)
      {:ok, lease} = Lease.acquire(fixture.message.id)

      worker =
        start_worker!(
          fixture,
          [
            tool_instances_by_alias: %{"web" => tool},
            test_tool_name: "web__web_search",
            test_tool_args: %{"query" => "late result"}
          ],
          %{lease: lease, lease_owner: self()}
        )

      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :tools})
      assert_receive {:waiting, request}, 5_000

      fixture
      |> message!()
      |> Ash.Changeset.for_update(:set_generation_state, %{status: :done}, actor: fixture.actor)
      |> Ash.update!(actor: fixture.actor)

      assert message!(fixture).generation_fence_token == lease.fence_token
      assert {:ok, :ok} = Lease.with_fence(lease, fn -> :ok end)
      send(request, :continue)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
      assert message!(fixture).status == :done
      assert length(steps!(fixture)) == 1
      assert length(Persistence.list_missing_tool_calls!(fixture.step_id)) == 1
      assert Persistence.load_step_for_followup!(fixture.step_id).results == []
      assert usage!(fixture).output_tokens == 3
      refute_provider_started(fixture)
    end

    test "a tool task crash preserves the provider usage committed before dispatch" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, provider_completed: :stop)
      # An invalid tool execution environment makes Executor's guarded entry point
      # crash; this exercises Worker DOWN handling rather than a soft tool error.
      worker = start_worker!(fixture, tool_instances_by_alias: :invalid_tool_environment)
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :tools})
      writer = Barrier.await_persistence(:provider_completed, :stop)
      usage = usage!(fixture)
      assert usage.status == :waiting_tools
      Barrier.release(writer)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert message!(fixture).status == :error
      assert usage!(fixture).id == usage.id
      assert usage!(fixture).output_tokens == 3
    end
  end

  describe "database failures" do
    for {name, code, failures, status, attempts, details} <- [
          {"a deadlock retries only the provider persistence transaction", "40P01", 1, :done, 2,
           []},
          {"a persistent serialization failure exhausts its database budget and becomes visible",
           "40001", 100, :error, 4, ["provider_completed", "4 database attempts"]},
          {"an ordinary SQL validation error is not retried as a rollback", "23514", 100, :error,
           1, ["provider_completed"]}
        ] do
      @tag code: code, failures: failures, status: status, attempts: attempts, details: details
      test name, %{code: code, failures: failures, status: status} = params do
        fixture = generation_fixture!()

        failure =
          inject_sql_failure!(
            "chat_message_steps",
            "BEFORE UPDATE",
            "NEW.id = #{fixture.step_id} AND NOT OLD.response_final AND NEW.response_final",
            code,
            failures
          )

        worker = start_worker!(fixture)
        monitor = Process.monitor(worker)
        {provider, _request} = await_provider!(fixture)
        send(provider, {:complete, :answer})
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
        message = message!(fixture, [:generation_recovery])
        assert message.status == status
        assert sql_attempts(failure) == params.attempts
        assert length(steps!(fixture)) == 1
        for detail <- params.details, do: assert(message.error_detail =~ detail)

        if message.status == :error do
          assert {:error, :invalid_status} =
                   GenerationSupervisor.resume_orphaned_message(message.id, actor: fixture.actor)
        end

        refute_provider_started(fixture)
      end
    end

    test "a permanent follow-up failure terminalizes and cannot be revived by recovery" do
      fixture = generation_fixture!(context: [test_fail_followup?: true])
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      {provider, original} = await_provider!(fixture)
      send(provider, {:complete, :tools})
      await_followup_prepared!(fixture)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      message = message!(fixture, [:generation_recovery])
      assert message.status == :error
      assert message.error_detail =~ "tool_followup"
      assert message.error_detail =~ "ArgumentError"
      assert StepRequests.request_for_step!(fixture.step_id, actor: fixture.actor) == original
      assert length(Persistence.load_step_for_followup!(fixture.step_id).results) == 1

      for _ <- 1..4 do
        assert {:error, :invalid_status} =
                 GenerationSupervisor.resume_orphaned_message(message.id, actor: fixture.actor)
      end

      refute_followup_prepared(fixture)
      refute_provider_started(fixture)
    end
  end

  describe "terminal finalization" do
    setup do
      fixture = generation_fixture!(context: [test_fail_followup?: true])
      %{fixture: fixture}
    end

    test "database unavailability retries only the durable terminal intent", %{fixture: fixture} do
      failure = inject_finalization_failure!(fixture, "57P03", 1)
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      trace_receives!(worker)
      fail_followup(fixture)
      await_failed_resolution!(worker)
      retry_failure_resolution_now!(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      message = message!(fixture, [:generation_recovery])
      assert message.status == :error
      assert message.generation_recovery["terminal_status"] == "error"
      assert sql_attempts(failure) == 2
      refute_followup_prepared(fixture)
      refute_provider_started(fixture)
    end

    test "the writer is retained until acknowledgement across lease validation",
         %{fixture: fixture} do
      failure = inject_finalization_failure!(fixture, "57P03", 1)
      message_id = fixture.message.id
      manager = Process.whereis(Lease)

      # The operation has returned its SQL connection, but its owner has not yet
      # received the persistence result. Validation must not kill that result.
      Barrier.attach(@persistence_stop, fn _event, _measurements, meta ->
        meta[:kind] == :failure_resolution and meta[:message_id] == message_id and
          meta[:outcome] == :ok and :terminal_ack
      end)

      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      trace_receives!(worker)
      {provider, _request} = await_provider!(fixture)

      # Run validation after the terminal write, but before the result reaches
      # the Worker. This is the periodic validator's otherwise timing-only race.
      :ok = :sys.suspend(manager)

      try do
        send(provider, {:complete, :tools})
        await_followup_prepared!(fixture)
        await_failed_resolution!(worker)
        retry_failure_resolution_now!(worker)
        writer = Barrier.await(:terminal_ack)
        writer_monitor = Process.monitor(writer.pid)
        assert message!(fixture).status == :error
        assert sql_attempts(failure) == 2
        :ok = Lease.trigger_validation()
        :ok = :sys.resume(manager)
        _ = :sys.get_state(manager)

        assert :sys.get_state(worker).persistence_op.task.pid == writer.pid
        Barrier.release(writer)
        assert_receive {:DOWN, ^writer_monitor, :process, _writer, :normal}, 5_000
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
        assert Process.whereis(Lease) == manager
        assert message!(fixture).generation_fence_token == nil
        refute_followup_prepared(fixture)
        refute_provider_started(fixture)
      after
        :sys.resume(manager)
      end
    end

    test "an outage before intent commit outlives three retries without losing terminal intent",
         %{fixture: fixture} do
      failure =
        inject_sql_failure!(
          "chat_messages",
          "BEFORE UPDATE",
          "NEW.id = #{fixture.message.id} AND " <>
            "NEW.generation_recovery IS DISTINCT FROM OLD.generation_recovery",
          "57P03",
          4
        )

      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      trace_receives!(worker)
      fail_followup(fixture)

      for attempt <- 1..4 do
        await_failed_resolution!(worker)
        state = :sys.get_state(worker)
        assert state.failure_plan.attempt == attempt
        assert state.failure_plan.terminal_status == :error
        assert state.phase == :recovering
        assert message!(fixture, [:generation_recovery]).generation_recovery == nil
        refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0

        # Queued steering cannot start another operation while the intent is pending.
        Worker.queue_changed(worker)
        send(worker, :consume_queued_steers)
        assert :sys.get_state(worker).persistence_op == nil
        retry_failure_resolution_now!(worker)
      end

      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert sql_attempts(failure) == 5
      assert message!(fixture).status == :error
      refute_followup_prepared(fixture)
      refute_provider_started(fixture)
    end

    test "a permanently failing finalizer releases its Worker but never resumes external work",
         %{fixture: fixture} do
      failure = inject_finalization_failure!(fixture, "23514", 100)
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      trace_receives!(worker)
      fail_followup(fixture)

      # Two bounded retries of the terminal reconciliation, then the owner stops.
      for _retry <- 1..2 do
        await_failed_resolution!(worker)
        retry_failure_resolution_now!(worker)
      end

      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert sql_attempts(failure) == 3
      message = message!(fixture, [:generation_recovery])
      assert message.status == :generating
      assert message.generation_recovery["terminal_status"] == "error"

      assert {:error, _} =
               GenerationSupervisor.resume_orphaned_message(message.id, actor: fixture.actor)

      assert GenerationSupervisor.generation_worker_pid(message.id) == nil
      assert sql_attempts(failure) == 4
      remove_sql_failure!(failure)

      assert {:ok, %{status: :error, recovery_finished?: true}} =
               GenerationSupervisor.resume_orphaned_message(message.id, actor: fixture.actor)

      assert message!(fixture).status == :error
      refute_followup_prepared(fixture)
      refute_provider_started(fixture)
    end
  end

  def observe_worker_query(_event, _measurements, metadata, {owner, worker}) do
    if self() == worker, do: send(owner, {:worker_query, worker, metadata.query})
  end

  defp fail_followup(fixture) do
    {provider, _request} = await_provider!(fixture)
    send(provider, {:complete, :tools})
    await_followup_prepared!(fixture)
  end

  defp inject_finalization_failure!(fixture, code, failures) do
    inject_sql_failure!(
      "chat_messages",
      "BEFORE UPDATE",
      "NEW.id = #{fixture.message.id} AND NEW.status = 'error' AND OLD.status = 'generating'",
      code,
      failures
    )
  end
end
