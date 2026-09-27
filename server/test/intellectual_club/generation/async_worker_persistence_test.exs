defmodule IntellectualClub.Generation.AsyncWorkerPersistenceTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.SubchatCostCache
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeSnapshots
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClub.Test.AsyncPersistenceAdapter
  alias IntellectualClubWeb.Bff.ChatPollPayload
  alias IntellectualClubWeb.Bff.PollCache

  require Ash.Query

  @event [:intellectual_club, :generation, :persistence]

  setup do
    unless Process.whereis(IntellectualClub.Generation.PersistenceTasks) do
      start_supervised!({Task.Supervisor, name: IntellectualClub.Generation.PersistenceTasks})
    end

    for child <- [RuntimeSnapshots, PollCache, SubchatCostCache] do
      unless Process.whereis(child), do: start_supervised!(child)
    end

    :ok
  end

  test "blocked initialization stays publicly generating until provider dispatch" do
    fixture = fixture()
    gate_operations(fixture, initialize: :start, initialize: :stop)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)

    for stage <- [:start, :stop] do
      assert_receive {:barrier, :initialize, ^stage, writer, _identity, gate}, 2_000
      state = :sys.get_state(worker)
      assert state.status == :initializing
      assert state.phase == :persisting
      assert state.stream_task == nil
      assert state.tool_task == nil

      send(worker, :publish_runtime_snapshot)

      assert Worker.get_current_state(worker) == %{
               status: :generating,
               phase: :persisting,
               step: nil
             }

      assert Worker.poll(worker, %{}) == Worker.get_current_state(worker)
      assert {:ok, snapshot} = RuntimeSnapshots.read(fixture.message.id, worker)
      assert snapshot.status == :generating
      assert snapshot.phase == :persisting
      assert snapshot.step == nil

      assert {:ok, payload} =
               ChatPollPayload.response(fixture.message, fixture.actor, {:ok, snapshot}, %{}, %{})

      assert payload.status == "generating"
      assert payload.phase == "persisting"
      assert payload.availability == "ready"
      assert payload.poll_after_ms == 1750
      assert payload.finished_at == nil
      assert payload.error_detail == nil
      assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :generating
      refute_receive {:provider_started, _, _, _}, 0
      refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
      send(writer, {gate, :continue})
    end

    assert_receive {:provider_started, _, _provider, _request}, 2_000
    _ = :sys.get_state(worker)
    assert {:ok, snapshot} = RuntimeSnapshots.read(fixture.message.id, worker)
    assert snapshot.status == :generating
    assert snapshot.phase == :provider
    cancel_worker(worker)
  end

  test "queued replacement accounts its deferred response before dispatch or cancellation of the receiving step" do
    for cancel? <- [false, true] do
      fixture = fixture()
      worker = start_worker(fixture)
      monitor = Process.monitor(worker)
      assert_receive {:provider_started, _, provider, original}, 2_000
      old_stream_ref = :sys.get_state(worker).stream_ref
      queued_handler = gate_operations(fixture, queued_steers: :start, queued_steers: :stop)
      gate_operations(fixture, interrupted_provider: :start, interrupted_provider: :stop)
      send(worker, :consume_queued_steers)
      assert_receive {:barrier, :queued_steers, :start, writer, _identity, gate}, 2_000
      complete_provider(worker, provider, :tools)
      assert :sys.get_state(worker).deferred_provider_event != nil

      assert {:ok, queued} =
               QueuedMessages.enqueue_steer(
                 fixture.message.id,
                 "Use the receiving request",
                 fixture.actor
               )

      send(writer, {gate, :continue})
      assert_receive {:barrier, :queued_steers, :stop, writer, _identity, gate}, 2_000
      [old_step, next_step] = steps(fixture)
      assert old_step.status == :canceled
      assert next_step.status == :waiting_provider
      assert :sys.get_state(worker).runtime_step.id == old_step.id
      assert {:ok, delivered} = QueuedMessages.get(queued.id, fixture.actor)
      assert delivered.status == :delivered
      :telemetry.detach(queued_handler)

      cancel_ref =
        if cancel? do
          ref = command(worker, :cancel_and_wait)
          state = :sys.get_state(worker)
          assert state.cancel_requested?
          assert state.runtime_step.output_tokens == 3
          ref
        end

      send(writer, {gate, :continue})
      assert_receive {:barrier, :interrupted_provider, :start, writer, _identity, gate}, 2_000
      assert :sys.get_state(worker).runtime_step.id == next_step.id
      assert_no_dispatch(worker)
      send_stale_completion(worker, old_stream_ref)
      send(writer, {gate, :continue})
      assert_receive {:barrier, :interrupted_provider, :stop, writer, _identity, gate}, 2_000
      recorded = assert_interrupted_accounting(fixture, original)
      assert_receiving_unaccounted(fixture, next_step.id)
      assert_no_dispatch(worker)
      if cancel?, do: refute_receive({^cancel_ref, _}, 0)
      send(writer, {gate, :continue})

      if cancel? do
        assert_receive {^cancel_ref, :ok}, 2_000
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
        assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :canceled
        assert Ash.get!(ChatMessageStep, next_step.id, actor: fixture.actor).status == :canceled
        receiving_request = StepRequests.request_for_step!(next_step.id, actor: fixture.actor)
        assert_receiving_request(fixture, next_step.id, original, receiving_request)
        refute_receive {:provider_started, _, _, _}, 0
      else
        assert_receive {:provider_started, _, receiving_provider, receiving_request}, 2_000
        assert_receiving_request(fixture, next_step.id, original, receiving_request)
        send_stale_completion(worker, old_stream_ref)
        finish_receiving_provider(fixture, worker, receiving_provider)
      end

      assert usage(fixture).id == recorded.id
      assert_interrupted_accounting(fixture, original)
    end
  end

  test "slow commit leaves snapshots readable and cancel suppresses deferred steering and tools" do
    fixture = fixture()

    gate_operations(fixture,
      provider_completed: :start,
      provider_completed: :stop,
      cancel: :start
    )

    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive {:barrier, :provider_completed, :start, writer, identity, gate}, 2_000

    state = :sys.get_state(worker)
    ref = state.persistence_op.task.ref
    assert state.persistence_op.task.pid == writer
    assert state.tool_task == nil
    assert state.phase == :persisting

    :ok = :sys.suspend(worker)

    try do
      assert {:ok, snapshot} = RuntimeSnapshots.read(fixture.message.id, worker)
      assert snapshot.phase == :persisting
      assert snapshot.status == :generating
      refute Map.has_key?(snapshot, :context)
      refute Map.has_key?(snapshot.step, :raw_request)
      refute Map.has_key?(snapshot.step, :raw_response)
      refute inspect(snapshot) =~ "large_raw_only"
    after
      :ok = :sys.resume(worker)
    end

    queued = enqueue_steer(fixture, worker, "must not reach tools")
    assert queued.status == :pending
    cancel_ref = command(worker, :cancel_and_wait)
    state = :sys.get_state(worker)
    assert state.cancel_requested?
    assert state.persistence_op.identity == identity
    refute_receive {^cancel_ref, _reply}, 0

    send(writer, {gate, :continue})
    assert_receive {:barrier, :provider_completed, :stop, writer, ^identity, gate}, 2_000
    assert load_step(fixture).status == :waiting_tools
    assert usage(fixture).output_tokens == 3
    assert :sys.get_state(worker).tool_task == nil
    send(writer, {gate, :continue})
    assert_receive {:barrier, :cancel, :start, cancel_writer, cancel_identity, cancel_gate}, 2_000

    # A late acknowledgment cannot replace the current cancellation operation.
    send(worker, {ref, {:persistence_result, identity, {:ok, :stale}}})
    state = :sys.get_state(worker)
    assert state.persistence_op.identity == cancel_identity
    assert state.tool_task == nil
    assert state.stream_task == nil
    send(cancel_writer, {cancel_gate, :continue})
    assert_receive {^cancel_ref, :ok}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :canceled
    assert usage(fixture).output_tokens == 3
    assert RuntimeSnapshots.read(fixture.message.id, worker) == :not_found
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "tools and next provider wait for committed acknowledgments and tools-phase steering is serialized" do
    fixture = fixture()

    gate_operations(fixture,
      provider_completed: :stop,
      tool_followup: :start,
      tool_followup: :stop
    )

    worker = start_worker(fixture)
    assert_receive {:provider_started, _, provider, original}, 2_000
    old_stream_ref = :sys.get_state(worker).stream_ref
    send(provider, {:complete, :tools})
    assert_receive {:barrier, :provider_completed, :stop, writer, _identity, gate}, 2_000
    assert length(Persistence.list_missing_tool_calls!(fixture.step_id)) == 1
    assert :sys.get_state(worker).tool_task == nil

    queued = enqueue_steer(fixture, worker, "serialized instruction")
    send(writer, {gate, :continue})

    assert_receive {:barrier, :tool_followup, :start, writer, _identity, gate}, 2_000
    assert Persistence.list_missing_tool_calls!(fixture.step_id) == []
    assert length(Persistence.load_step_for_followup!(fixture.step_id).results) == 1
    assert :sys.get_state(worker).stream_task == nil
    refute_receive {:provider_started, _, _, _}, 0
    send(writer, {gate, :continue})
    assert_receive {:barrier, :tool_followup, :stop, writer, _identity, gate}, 2_000
    [old_step, next_step] = steps(fixture)
    assert old_step.status == :done
    assert next_step.status == :waiting_provider

    assert {:ok, %{status: :delivered, steering_item_id: steering_item_id}} =
             QueuedMessages.get(queued.id, fixture.actor)

    assert is_integer(steering_item_id)
    assert :sys.get_state(worker).stream_task == nil

    send(worker, {:provider_event, old_stream_ref, {:response_complete, %{raw_response: %{}}}})
    _ = :sys.get_state(worker)
    send(writer, {gate, :continue})
    assert_receive {:provider_started, _, _provider, next_request}, 2_000
    assert Enum.count(next_request["messages"], &(&1["content"] == "serialized instruction")) == 1
    assert StepRequests.request_for_step!(old_step.id, actor: fixture.actor) == original
    assert StepRequests.request_for_step!(next_step.id, actor: fixture.actor) == next_request
    assert length(Persistence.load_step_for_followup!(fixture.step_id).results) == 1
    cancel_worker(worker)
  end

  test "cancel during retry publication cancels the receiving step without starting another request" do
    fixture = fixture()
    gate_operations(fixture, auto_retry: :stop)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, original}, 2_000
    send(provider, :retry)
    assert_receive {:barrier, :auto_retry, :stop, writer, _identity, gate}, 2_000
    [old_step, next_step] = steps(fixture)
    assert old_step.status == :error
    assert next_step.status == :waiting_provider
    cancel_ref = command(worker, :cancel_and_wait)
    assert :sys.get_state(worker).cancel_requested?
    send(writer, {gate, :continue})
    assert_receive {^cancel_ref, :ok}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert Ash.get!(ChatMessageStep, next_step.id, actor: fixture.actor).status == :canceled
    assert StepRequests.request_for_step!(old_step.id, actor: fixture.actor) == original
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "crashes before and after provider commit recover from durable state without replaying a committed response" do
    for stage <- [:start, :stop] do
      fixture = fixture()
      handler = gate_operations(fixture, provider_completed: stage)
      worker = start_worker(fixture)
      monitor = Process.monitor(worker)
      assert_receive {:provider_started, _, provider, _request}, 2_000
      send(provider, {:complete, :answer})
      assert_receive {:barrier, :provider_completed, ^stage, writer, _identity, gate}, 2_000
      send(writer, {gate, :crash})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
      assert RuntimeSnapshots.read(fixture.message.id, worker) == :not_found
      assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :generating
      :telemetry.detach(handler)

      mode = if stage == :start, do: :steered_waiting_provider, else: :finalize_completed_step
      expected_status = if stage == :start, do: :waiting_provider, else: :done
      assert load_step(fixture).status == expected_status
      resume_handler = gate_operations(fixture, done: :stop)
      recovered = start_worker(fixture, initial_resume_mode: mode)
      recovered_monitor = Process.monitor(recovered)

      if stage == :start do
        assert_receive {:provider_started, _, provider, _request}, 2_000
        send(provider, {:complete, :answer})
      end

      assert_receive {:barrier, :done, :stop, writer, _identity, gate}, 2_000
      send(writer, {gate, :continue})
      assert_receive {:DOWN, ^recovered_monitor, :process, ^recovered, :normal}, 2_000
      :telemetry.detach(resume_handler)
      assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :done
      assert usage(fixture).output_tokens == 3
      assert length(steps(fixture)) == 1
      refute_receive {:provider_started, _, _, _}, 0
    end
  end

  test "worker kill also kills its blocked writer and removes the snapshot owner" do
    fixture = fixture()
    gate_operations(fixture, provider_completed: :start)
    worker = start_worker(fixture)
    worker_monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :answer})
    assert_receive {:barrier, :provider_completed, :start, writer, _identity, _gate}, 2_000
    writer_monitor = Process.monitor(writer)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 2_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :killed}, 2_000
    assert RuntimeSnapshots.read(fixture.message.id, worker) == :not_found
    assert load_step(fixture).status == :waiting_provider
  end

  test "fence loss drains a committed intermediate writer without dispatching its tools" do
    fixture = fixture()
    gate_operations(fixture, provider_completed: :stop)
    {:ok, lease} = Lease.acquire(fixture.message.id)
    worker = start_worker(fixture, [], %{lease: lease, lease_owner: self()})
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive {:barrier, :provider_completed, :stop, writer, _identity, gate}, 2_000
    writer_monitor = Process.monitor(writer)

    current = Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor)
    assert current.generation_fence_token == lease.fence_token

    current
    |> Ash.Changeset.for_update(:set_generation_fence, %{generation_fence_token: nil},
      actor: fixture.actor
    )
    |> Ash.update!(actor: fixture.actor)

    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).generation_fence_token ==
             nil

    Lease.trigger_validation()
    _ = :sys.get_state(lease.manager)
    state = :sys.get_state(worker)
    assert state.lease_lost?
    assert state.persistence_op.task.pid == writer
    assert state.tool_task == nil
    refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
    refute_receive {:DOWN, ^writer_monitor, :process, ^writer, _}, 0
    Worker.queue_changed(worker)
    send(worker, :consume_queued_steers)
    assert :sys.get_state(worker).persistence_op.task.pid == writer

    send(writer, {gate, :continue})
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :generating
    assert length(Persistence.list_missing_tool_calls!(fixture.step_id)) == 1
    assert Persistence.load_step_for_followup!(fixture.step_id).results == []
    refute_receive {:provider_started, _, _, _}, 0
    assert {:ok, replacement} = Lease.reserve(fixture.message.id)
    assert :ok = Lease.release(replacement)
  end

  test "fence validation after cancellation commit preserves its acknowledged cancel result" do
    fixture = fixture()
    gate_operations(fixture, cancel: :stop)
    {:ok, lease} = Lease.acquire(fixture.message.id)
    worker = start_worker(fixture, [], %{lease: lease, lease_owner: self()})
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, _provider, _request}, 2_000
    cancel_ref = command(worker, :cancel_and_wait)
    assert_receive {:barrier, :cancel, :stop, writer, _identity, gate}, 2_000
    writer_monitor = Process.monitor(writer)
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :canceled

    Lease.trigger_validation()
    _ = :sys.get_state(lease.manager)
    assert :sys.get_state(worker).lease_lost?
    refute_receive {^cancel_ref, _reply}, 0
    refute_receive {:DOWN, ^writer_monitor, :process, ^writer, _}, 0
    send(writer, {gate, :continue})
    assert_receive {^cancel_ref, :ok}, 2_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    message = Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor)
    assert message.status == :canceled
    assert message.generation_fence_token == nil
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "lease remains owned until the in-flight write and cancellation resolve" do
    fixture = fixture()
    gate_operations(fixture, provider_completed: :stop, cancel: :start)
    {:ok, lease} = Lease.acquire(fixture.message.id)
    worker = start_worker(fixture, [], %{lease: lease, lease_owner: self()})
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :answer})
    assert_receive {:barrier, :provider_completed, :stop, writer, identity, gate}, 2_000
    assert identity.lease_ref == lease.ref
    assert identity.fence_token == lease.fence_token
    cancel_ref = command(worker, :cancel_and_wait)
    assert :sys.get_state(worker).cancel_requested?
    assert Lease.acquire(fixture.message.id) == {:error, :already_running}
    send(writer, {gate, :continue})
    assert_receive {:barrier, :cancel, :start, writer, _identity, gate}, 2_000
    assert Lease.acquire(fixture.message.id) == {:error, :already_running}
    monitor = Process.monitor(worker)
    send(writer, {gate, :continue})
    assert_receive {^cancel_ref, :ok}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    {:ok, replacement} = Lease.reserve(fixture.message.id)
    assert replacement.ref != lease.ref
    assert :ok = Lease.release(replacement)
  end

  test "cancel retains usage from a provider event deferred behind a queued-steering read" do
    fixture = fixture()
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    provider_monitor = Process.monitor(provider)
    gate_operations(fixture, queued_steers: :start, cancel: :start)
    send(worker, :consume_queued_steers)
    assert_receive {:barrier, :queued_steers, :start, writer, _identity, gate}, 2_000
    send(provider, {:complete, :answer})
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :normal}, 2_000
    assert :sys.get_state(worker).deferred_provider_event != nil
    cancel_ref = command(worker, :cancel_and_wait)
    state = :sys.get_state(worker)
    assert state.cancel_requested?
    assert state.runtime_step.output_tokens == 3
    send(writer, {gate, :continue})
    assert_receive {:barrier, :cancel, :start, writer, _identity, gate}, 2_000
    send(writer, {gate, :continue})
    assert_receive {^cancel_ref, :ok}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert usage(fixture).output_tokens == 3
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :canceled
  end

  test "retry expiration during a queued-steering read is not lost" do
    keys = [:generation_auto_retry_backoff_ms, :generation_auto_retry_jitter_ratio]
    previous = Enum.map(keys, &{&1, Application.get_env(:intellectual_club, &1)})
    Application.put_env(:intellectual_club, :generation_auto_retry_backoff_ms, [60_000])
    Application.put_env(:intellectual_club, :generation_auto_retry_jitter_ratio, 0.0)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:intellectual_club, key)
        {key, value} -> Application.put_env(:intellectual_club, key, value)
      end)
    end)

    fixture = fixture()
    worker = start_worker(fixture)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    gate_operations(fixture, auto_retry: :stop, queued_steers: :start)
    send(provider, :retry)
    assert_receive {:barrier, :auto_retry, :stop, writer, identity, gate}, 2_000
    ref = :sys.get_state(worker).persistence_op.task.ref

    # Wait for the exact acknowledgment to enter the Worker, then use a system
    # call barrier to observe the installed backoff without timing-dependent polls.
    :erlang.trace(worker, true, [:receive])

    try do
      send(writer, {gate, :continue})

      assert_receive {:trace, ^worker, :receive,
                      {^ref, {:persistence_result, ^identity, _result}}},
                     2_000

      assert :sys.get_state(worker).phase == :backoff
    after
      :erlang.trace(worker, false, [:receive])
    end

    {_timer, retry_token} = :sys.get_state(worker).retry_timer_ref
    send(worker, :consume_queued_steers)
    assert_receive {:barrier, :queued_steers, :start, writer, _identity, gate}, 2_000
    send(worker, {:retry_current_step, retry_token})
    state = :sys.get_state(worker)
    assert state.continuation == :start_stream
    assert state.retry_timer_ref == nil
    send(writer, {gate, :continue})
    assert_receive {:barrier, :queued_steers, :start, writer, _identity, gate}, 2_000
    send(writer, {gate, :continue})
    assert_receive {:provider_started, _, _provider, _request}, 2_000
    cancel_worker(worker)
  end

  test "steering pending behind a retry commit does not count a second provider attempt" do
    fixture = fixture()
    gate_operations(fixture, auto_retry: :stop)
    worker = start_worker(fixture)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    gate_operations(fixture, queued_steers: :stop)
    send(provider, :retry)
    assert_receive {:barrier, :auto_retry, :stop, writer, _identity, gate}, 2_000
    queued = enqueue_steer(fixture, worker, "steer the pending retry")
    send(writer, {gate, :continue})
    assert_receive {:barrier, :queued_steers, :stop, writer, _identity, gate}, 2_000
    assert :sys.get_state(worker).step_attempt == 2
    assert :sys.get_state(worker).stream_task == nil
    refute_receive {:provider_started, _, _, _}, 0
    send(writer, {gate, :continue})
    assert_receive {:provider_started, _, _provider, request}, 2_000
    state = :sys.get_state(worker)

    assert {:ok, %{status: :delivered, steering_item_id: steering_item_id}} =
             QueuedMessages.get(queued.id, fixture.actor)

    assert is_integer(steering_item_id)
    assert state.step_attempt == 2
    assert state.step_sequence == 3
    assert Enum.count(request["messages"], &(&1["content"] == "steer the pending retry")) == 1
    cancel_worker(worker)
  end

  test "pending cancellation reconciles a committed retry when its acknowledgment is lost" do
    fixture = fixture()
    gate_operations(fixture, auto_retry: :stop, failure_resolution: :start)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, :retry)
    assert_receive {:barrier, :auto_retry, :stop, writer, _identity, gate}, 2_000
    [old_step, next_step] = steps(fixture)
    cancel_ref = command(worker, :cancel_and_wait)
    assert :sys.get_state(worker).cancel_requested?
    send(writer, {gate, :crash})
    assert_receive {:barrier, :failure_resolution, :start, writer, _identity, gate}, 2_000
    refute_receive {^cancel_ref, _reply}, 0
    send(writer, {gate, :continue})
    assert_receive {^cancel_ref, :ok}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert Ash.get!(ChatMessageStep, old_step.id, actor: fixture.actor).status == :error
    assert Ash.get!(ChatMessageStep, next_step.id, actor: fixture.actor).status == :canceled
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "a committed round transition reconciles in place after writer failure and ignores its late result" do
    fixture = fixture()
    handler = gate_operations(fixture, tool_followup: :stop)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive {:barrier, :tool_followup, :stop, writer, identity, gate}, 2_000
    ref = :sys.get_state(worker).persistence_op.task.ref
    [old_step, next_step] = steps(fixture)
    request = StepRequests.request_for_step!(next_step.id, actor: fixture.actor)
    :telemetry.detach(handler)
    send(writer, {gate, :crash})

    assert_receive {:provider_started, _, _provider, ^request}, 2_000
    refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
    assert old_step.status == :done
    assert next_step.status == :waiting_provider
    assert :sys.get_state(worker).runtime_step.id == next_step.id

    send(worker, {ref, {:persistence_result, identity, {:ok, :stale}}})
    assert :sys.get_state(worker).runtime_step.id == next_step.id
    assert length(Persistence.load_step_for_followup!(old_step.id).results) == 1

    assert Ash.get!(ChatMessage, fixture.message.id,
             actor: fixture.actor,
             load: [:generation_recovery]
           ).generation_recovery == nil

    cancel_worker(worker)
  end

  test "lost queued followup ACK installs the committed successor without generation recovery" do
    fixture = fixture()
    completed_handler = gate_operations(fixture, provider_completed: :stop)
    followup_handler = gate_operations(fixture, tool_followup: :stop)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive {:barrier, :provider_completed, :stop, writer, _identity, gate}, 2_000

    assert {:ok, queued} =
             QueuedMessages.enqueue_steer(fixture.message.id, "Queued followup", fixture.actor)

    :telemetry.detach(completed_handler)
    send(writer, {gate, :continue})
    assert_receive {:barrier, :tool_followup, :stop, writer, _identity, gate}, 2_000
    [source, successor] = steps(fixture)
    request = StepRequests.request_for_step!(successor.id, actor: fixture.actor)
    assert Enum.count(request["messages"], &(&1["content"] == "Queued followup")) == 1
    assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, fixture.actor)
    :telemetry.detach(followup_handler)
    send(writer, {gate, :crash})

    assert_receive {:provider_started, _, _provider, ^request}, 2_000
    refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
    assert :sys.get_state(worker).runtime_step.id == successor.id
    assert Enum.map(steps(fixture), & &1.id) == [source.id, successor.id]
    assert length(Persistence.load_step_for_followup!(source.id).results) == 1

    assert Ash.get!(ChatMessage, fixture.message.id,
             actor: fixture.actor,
             load: [:generation_recovery]
           ).generation_recovery == nil

    cancel_worker(worker)
  end

  test "queued steer rejection preserves a provider backoff intercepted before its timer starts" do
    keys = [:generation_auto_retry_backoff_ms, :generation_auto_retry_jitter_ratio]
    previous = Enum.map(keys, &{&1, Application.get_env(:intellectual_club, &1)})
    Application.put_env(:intellectual_club, :generation_auto_retry_backoff_ms, [60_000])
    Application.put_env(:intellectual_club, :generation_auto_retry_jitter_ratio, 0.0)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:intellectual_club, key)
        {key, value} -> Application.put_env(:intellectual_club, key, value)
      end)
    end)

    fixture = fixture()
    gate_operations(fixture, auto_retry: :stop, steering_rejection: :stop)

    worker =
      start_worker(fixture,
        adapter_module: IntellectualClub.Test.SteeringFailureAdapter,
        test_reject_steering?: true
      )

    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, :retry)
    assert_receive {:barrier, :auto_retry, :stop, writer, _identity, gate}, 2_000

    assert {:ok, queued} =
             QueuedMessages.enqueue_steer(
               fixture.message.id,
               "Rejected during backoff",
               fixture.actor
             )

    send(worker, :consume_queued_steers)
    assert :sys.get_state(worker).queue_dirty?
    send(writer, {gate, :continue})
    assert_receive {:barrier, :steering_rejection, :stop, writer, identity, gate}, 2_000
    state = :sys.get_state(worker)
    assert state.continuation == {:backoff, 60_000}
    assert state.retry_timer_ref == nil

    assert {:ok, %{status: :blocked, blocked_reason: "steering_failed"}} =
             QueuedMessages.get(queued.id, fixture.actor)

    ref = state.persistence_op.task.ref
    :erlang.trace(worker, true, [:receive])
    send(writer, {gate, :continue})
    assert_receive {:trace, ^worker, :receive, {^ref, {:persistence_result, ^identity, _}}}, 2_000
    state = :sys.get_state(worker)
    assert state.phase == :backoff
    {timer, _token} = state.retry_timer_ref
    assert Process.read_timer(timer) > 50_000
    refute_receive {:provider_started, _, _, _}, 0

    # A queued retry sweep must not replace the existing provider timer either.
    handler = gate_operations(fixture, queued_steers: :stop)
    send(worker, :consume_queued_steers)
    assert_receive {:barrier, :queued_steers, :stop, writer, identity, gate}, 2_000
    :telemetry.detach(handler)
    ref = :sys.get_state(worker).persistence_op.task.ref
    send(writer, {gate, :continue})
    assert_receive {:trace, ^worker, :receive, {^ref, {:persistence_result, ^identity, _}}}, 2_000
    assert :sys.get_state(worker).retry_timer_ref == state.retry_timer_ref
    assert Process.read_timer(timer) > 50_000
    :erlang.trace(worker, false, [:receive])
    refute_receive {:provider_started, _, _, _}, 0
    cancel_worker(worker)
  end

  test "steering deferred behind a round transition replaces only its receiving step before provider dispatch" do
    fixture = fixture()
    gate_operations(fixture, tool_followup: :stop)
    worker = start_worker(fixture)
    assert_receive {:provider_started, _, provider, original}, 2_000
    gate_operations(fixture, queued_steers: :stop)
    send(provider, {:complete, :tools})
    assert_receive {:barrier, :tool_followup, :stop, writer, _identity, gate}, 2_000
    [old_step, receiving_step] = steps(fixture)
    receiving_request = StepRequests.request_for_step!(receiving_step.id, actor: fixture.actor)
    queued = enqueue_steer(fixture, worker, "after round commit")
    send(writer, {gate, :continue})
    assert_receive {:barrier, :queued_steers, :stop, writer, _identity, gate}, 2_000
    refute_receive {:provider_started, _, _, _}, 0
    send(writer, {gate, :continue})

    assert_receive {:barrier, :queued_steers, :stop, writer, _identity, gate}, 2_000
    send(writer, {gate, :continue})

    assert_receive {:provider_started, _, _provider, steered_request}, 2_000
    steered_id = :sys.get_state(worker).runtime_step.id
    assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, fixture.actor)
    assert Enum.count(steered_request["messages"], &(&1["content"] == "after round commit")) == 1
    assert :sys.get_state(worker).runtime_step.id == steered_id
    assert StepRequests.request_for_step!(old_step.id, actor: fixture.actor) == original

    assert StepRequests.request_for_step!(receiving_step.id, actor: fixture.actor) ==
             receiving_request

    assert Ash.get!(ChatMessageStep, receiving_step.id, actor: fixture.actor).status == :canceled
    cancel_worker(worker)
  end

  test "a late tool result cannot mutate a completed parent with the same live fence" do
    fixture = fixture()
    owner = self()

    server =
      start_supervised!(
        {Bandit,
         plug:
           {IntellectualClub.TestSupport.WebSearchServer,
            handler: fn _path, _payload -> {:wait, owner} end, test_pid: owner},
         scheme: :http,
         port: 0}
      )

    {:ok, {_host, port}} = ThousandIsland.listener_info(server)

    tool = %IntellectualClub.Tools.ToolInstance{
      type: "native-web-search",
      config: %{
        "providers" => ["brave"],
        "provider_options" => %{
          "brave" => %{"api_base_url" => "http://127.0.0.1:#{port}/brave"}
        }
      },
      secrets: %{"brave_api_key" => "test-key"}
    }

    {:ok, lease} = Lease.acquire(fixture.message.id)

    worker =
      start_worker(
        fixture,
        [
          tool_instances_by_alias: %{"web" => tool},
          test_tool_name: "web__web_search",
          test_tool_args: %{"query" => "late result"}
        ],
        %{lease: lease, lease_owner: self()}
      )

    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive {:waiting, request}, 2_000

    message = Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor)

    message
    |> Ash.Changeset.for_update(:set_generation_state, %{status: :done}, actor: fixture.actor)
    |> Ash.update!(actor: fixture.actor)

    assert Ash.get!(ChatMessage, message.id, actor: fixture.actor).generation_fence_token ==
             lease.fence_token

    assert {:ok, :ok} = Lease.with_fence(lease, fn -> :ok end)
    send(request, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
    assert Ash.get!(ChatMessage, message.id, actor: fixture.actor).status == :done
    assert length(steps(fixture)) == 1
    assert length(Persistence.list_missing_tool_calls!(fixture.step_id)) == 1
    assert Persistence.load_step_for_followup!(fixture.step_id).results == []
    assert usage(fixture).output_tokens == 3
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "tool task crash preserves the provider usage committed before dispatch" do
    fixture = fixture()
    gate_operations(fixture, provider_completed: :stop)
    # An invalid tool execution environment makes Executor's guarded entry point
    # crash; this exercises Worker DOWN handling rather than a soft tool error.
    worker = start_worker(fixture, tool_instances_by_alias: :invalid_tool_environment)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive {:barrier, :provider_completed, :stop, writer, _identity, gate}, 2_000
    usage_id = usage(fixture).id
    assert usage(fixture).status == :waiting_tools
    send(writer, {gate, :continue})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :error
    assert usage(fixture).id == usage_id
    assert usage(fixture).output_tokens == 3
  end

  test "cancel received during a terminal commit cannot roll back a completed generation" do
    fixture = fixture()
    gate_operations(fixture, done: :stop)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :answer})
    assert_receive {:barrier, :done, :stop, writer, _identity, gate}, 2_000
    cancel_ref = command(worker, :cancel_and_wait)
    assert :sys.get_state(worker).cancel_requested?
    send(writer, {gate, :continue})
    assert_receive {^cancel_ref, {:error, :generation_not_active}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :done
  end

  test "a lost snapshot registration is republished by its still-current Worker" do
    fixture = fixture()
    worker = start_worker(fixture)
    assert_receive {:provider_started, _, _provider, _request}, 2_000
    {:ok, before} = RuntimeSnapshots.read(fixture.message.id, worker)
    before_identity = :sys.get_state(worker).snapshot_identity

    :sys.replace_state(worker, fn state ->
      RuntimeSnapshots.remove(state.context.message_id, state.snapshot_identity)
      state
    end)

    send(worker, :publish_runtime_snapshot)
    _ = :sys.get_state(worker)
    assert {:ok, after_loss} = RuntimeSnapshots.read(fixture.message.id, worker)
    assert :sys.get_state(worker).snapshot_identity != before_identity
    refute Map.has_key?(after_loss, :identity)
    assert after_loss.step == before.step
    assert after_loss.phase == :provider
    cancel_worker(worker)
  end

  test "a replacement fence rejects the blocked old writer without clearing the successor token" do
    fixture = fixture()
    gate_operations(fixture, provider_completed: :start)
    {:ok, lease} = Lease.acquire(fixture.message.id)
    worker = start_worker(fixture, [], %{lease: lease, lease_owner: self()})
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :answer})
    assert_receive {:barrier, :provider_completed, :start, writer, _identity, gate}, 2_000

    :sys.replace_state(worker, fn state ->
      :ok = Lease.release(state.lease)
      state
    end)

    {:ok, successor} = Lease.acquire(fixture.message.id)

    try do
      send(writer, {gate, :continue})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
      assert load_step(fixture).status == :waiting_provider

      assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).generation_fence_token ==
               successor.fence_token

      assert Lease.valid?(successor)
    after
      Lease.release(successor)
    end
  end

  # Telemetry callbacks run inside the writer, giving deterministic barriers on
  # both sides of the actual persistence call without changing production APIs.
  def persistence_barrier(event, _measurements, metadata, {owner, message_id, gates}) do
    stage = List.last(event)

    if metadata.message_id == message_id and {metadata.kind, stage} in gates do
      gate = make_ref()
      send(owner, {:barrier, metadata.kind, stage, self(), Map.delete(metadata, :outcome), gate})

      receive do
        {^gate, :continue} -> :ok
        {^gate, :crash} -> Process.exit(self(), :kill)
      end
    end
  end

  defp gate_operations(fixture, gates) do
    handler = "async-worker-#{fixture.message.id}-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [@event ++ [:start], @event ++ [:stop]],
        &__MODULE__.persistence_barrier/4,
        {self(), fixture.message.id, gates}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  # Observe the terminal event in the Worker mailbox before sending a command;
  # provider DOWN alone does not order messages sent to two different processes.
  defp complete_provider(worker, provider, completion) do
    stream_ref = :sys.get_state(worker).stream_ref
    :erlang.trace(worker, true, [:receive])

    try do
      send(provider, {:complete, completion})

      assert_receive {:trace, ^worker, :receive,
                      {:provider_event, ^stream_ref, {:response_complete, _meta}}},
                     2_000

      _ = :sys.get_state(worker)
    after
      :erlang.trace(worker, false, [:receive])
    end
  end

  defp assert_no_dispatch(worker) do
    state = :sys.get_state(worker)
    assert state.phase == :persisting
    assert state.stream_task == nil
    assert state.tool_task == nil
    refute_receive {:provider_started, _, _, _}, 0
  end

  defp send_stale_completion(worker, stream_ref) do
    send(worker, {:provider_event, stream_ref, {:trace, {:set_text, "late", :answer, 1, "Late"}}})

    send(
      worker,
      {:provider_event, stream_ref,
       {:response_complete, %{raw_response: %{"id" => "stale"}, usage: %{output_tokens: 999}}}}
    )

    _ = :sys.get_state(worker)
  end

  defp assert_interrupted_accounting(fixture, original) do
    step =
      Ash.get!(ChatMessageStep, fixture.step_id,
        actor: fixture.actor,
        load: [:raw_response, items: [:contents]]
      )

    assert step.status == :canceled
    refute step.response_final
    assert step.raw_response["id"] == "async_response"
    assert StepRequests.request_for_step!(step.id, actor: fixture.actor) == original
    refute Enum.any?(step.items, &(&1.type in [:answer, :tool_call, :tool_result, :artifact]))
    assert Persistence.list_missing_tool_calls!(step.id) == []
    assert Persistence.load_step_for_followup!(step.id).results == []
    recorded = usage(fixture)
    assert recorded.chat_message_step_id_snapshot == fixture.step_id
    assert recorded.status == :canceled
    assert recorded.input_tokens == 12
    assert recorded.output_tokens == 3
    assert recorded.cached_input_tokens == 4
    assert recorded.reasoning_tokens == 1
    assert recorded.cost == 0.125
    assert recorded.raw_usage["output_tokens"] == 3
    assert step.input_tokens == recorded.input_tokens
    assert step.output_tokens == recorded.output_tokens
    assert step.cost == recorded.cost
    recorded
  end

  defp assert_receiving_unaccounted(fixture, step_id) do
    step = Ash.get!(ChatMessageStep, step_id, actor: fixture.actor, load: [:raw_response])
    assert step.status == :waiting_provider
    assert step.raw_response == nil
    assert step.input_tokens == nil
    assert step.output_tokens == nil
    assert step.cost == nil

    records =
      LlmUsageRecord
      |> Ash.Query.filter(chat_message_step_id_snapshot == ^step_id)
      |> Ash.read!(actor: fixture.actor)

    assert records == []
  end

  defp assert_receiving_request(fixture, step_id, original, request) do
    assert request ==
             Map.update!(original, "messages", fn messages ->
               messages ++ [%{"role" => "user", "content" => "Use the receiving request"}]
             end)

    assert StepRequests.request_for_step!(step_id, actor: fixture.actor) == request
  end

  defp finish_receiving_provider(fixture, worker, provider) do
    monitor = Process.monitor(worker)
    send(provider, {:complete, {:answer, "Receiving answer"}})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000

    message =
      Ash.get!(ChatMessage, fixture.message.id,
        actor: fixture.actor,
        load: [steps: [items: [:contents]]]
      )

    assert message.status == :done

    answers =
      message.steps
      |> Enum.flat_map(& &1.items)
      |> Enum.filter(&(&1.type == :answer))
      |> Enum.flat_map(& &1.contents)
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.map(& &1.content_text)

    assert answers == ["Receiving answer"]

    records =
      LlmUsageRecord
      |> Ash.Query.filter(chat_message_id_snapshot == ^fixture.message.id)
      |> Ash.Query.sort(step_sequence: :asc)
      |> Ash.read!(actor: fixture.actor)

    assert Enum.map(records, & &1.chat_message_step_id_snapshot) ==
             Enum.map(steps(fixture), & &1.id)

    assert Enum.map(records, & &1.output_tokens) == [3, 3]
    assert Enum.map(records, & &1.cost) == [0.125, 0.125]
  end

  defp enqueue_steer(fixture, worker, text) do
    assert {:ok, queued} = QueuedMessages.enqueue_steer(fixture.message.id, text, fixture.actor)
    Worker.queue_changed(worker)
    queued
  end

  defp command(worker, command) do
    ref = make_ref()
    send(worker, {:"$gen_call", {self(), ref}, command})
    ref
  end

  defp cancel_worker(worker) do
    monitor = Process.monitor(worker)
    assert Worker.cancel_and_wait(worker) == :ok
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
  end

  defp start_worker(fixture, overrides \\ [], opts \\ %{}) do
    context = Map.merge(fixture.context, Map.new(overrides))

    opts =
      if Map.has_key?(opts, :lease) do
        opts
      else
        assert {:ok, lease} = Lease.acquire(fixture.message.id)
        Map.merge(opts, %{lease: lease, lease_owner: self()})
      end

    start_supervised!(%{
      id: {Worker, fixture.message.id, make_ref()},
      start: {Worker, :start_link, [Map.put(opts, :context, context)]},
      restart: :temporary
    })
  end

  defp fixture do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Async persistence",
          type: :openrouter_chat_completion,
          auth_method: :api_key,
          base_url: "http://localhost:1",
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "test-model",
          parameters: %{},
          timeout_seconds: 5
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", llm_configuration_id: configuration.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, input} = Threads.add_message_to_end(chat, :user, "Initial request", actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{
          chat_id: chat.id,
          parent_id: input.id,
          llm_configuration_id: configuration.id,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    request = %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => "Initial request"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(message.id, request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: AsyncPersistenceAdapter,
      request_payload: request,
      timeout_ms: 5_000,
      chunk_delay_ms: 0,
      test_pid: self(),
      tool_instances_by_alias: %{},
      max_tool_rounds: 8,
      tools_payload: []
    }

    %{actor: actor, message: message, step_id: step_id, context: context}
  end

  defp steps(fixture) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^fixture.message.id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: fixture.actor)
  end

  defp load_step(fixture), do: Ash.get!(ChatMessageStep, fixture.step_id, actor: fixture.actor)

  defp usage(fixture) do
    [usage] =
      LlmUsageRecord
      |> Ash.Query.filter(chat_message_step_id_snapshot == ^fixture.step_id)
      |> Ash.read!(actor: fixture.actor)

    usage
  end
end
