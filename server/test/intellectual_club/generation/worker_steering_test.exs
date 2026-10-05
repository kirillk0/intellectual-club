defmodule IntellectualClub.Generation.WorkerSteeringTest do
  @moduledoc """
  Queued steering interrupts the running provider request: the Worker commits
  the steering items into a new receiving step, restarts the provider with the
  steered request and ignores events of the interrupted stream. Telemetry
  barriers hold the persistence writers to check every boundary.
  """
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Test.GenerationRuntime

  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Generation.{Lease, Persistence, StepRequests, Worker}
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClub.Test.GenerationRuntime.{Barrier, ScriptedAdapter}

  require Ash.Query

  setup do
    unless Process.whereis(IntellectualClub.Generation.PersistenceTasks) do
      start_supervised!({Task.Supervisor, name: IntellectualClub.Generation.PersistenceTasks})
    end

    :ok
  end

  describe "provider interruption" do
    test "steering interrupts the provider, ignores stale events and creates a new immutable step" do
      # Every attempt streams a partial answer and tries to rewrite its request.
      partial = [
        {:emit, {:trace, {:set_step_raw_request, %{"mutated_by_event" => true}}}},
        {:text, :answer, "Discarded partial answer"},
        :await
      ]

      fixture =
        generation_fixture!(
          context: [
            test_script: fn attempt ->
              if attempt == 1, do: [:share_emit | partial], else: partial
            end
          ]
        )

      %{worker: worker, monitor: monitor, step_id: step_id} = gen = start_generation!(fixture)
      original = fixture.context.request_payload
      message_id = fixture.message.id
      assert_receive {:provider_emit, ^message_id, _provider, stale_emit}
      assert {:error, :already_running} = Lease.acquire(message_id)

      queued = enqueue_steer!(gen, "Change direction", worker)
      {provider, restarted_request} = await_provider!(gen)
      receiving_step_id = Worker.get_current_state(worker).step.id
      refute receiving_step_id == step_id
      assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, gen.actor)

      assert List.last(restarted_request["messages"]) == %{
               "role" => "user",
               "content" => "Change direction"
             }

      stale_emit.(
        {:response_complete, %{raw_request: original, raw_response: %{"id" => "stale"}}}
      )

      assert %{status: :generating} = Worker.get_current_state(worker)

      send(provider, {:complete, {:answer, "Restarted answer"}})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      message = message!(gen, steps: [:raw_response, items: [:contents]])
      assert message.status == :done
      assert [interrupted, step] = Enum.sort_by(message.steps, & &1.sequence)
      assert interrupted.id == step_id
      assert interrupted.status == :canceled
      refute Enum.any?(interrupted.items, &(&1.type == :answer))
      assert StepRequests.request_for_step!(interrupted.id, actor: gen.actor) == original
      assert step.id == receiving_step_id
      assert step.sequence == 2
      assert StepRequests.request_for_step!(step.id, actor: gen.actor) == restarted_request
      assert Enum.map(Enum.sort_by(step.items, & &1.sequence), & &1.type) == [:steering, :answer]
      assert item_text(Enum.find(step.items, &(&1.type == :steering))) == "Change direction"
      answer = item_text(Enum.find(step.items, &(&1.type == :answer)))
      assert answer == "Restarted answer"
    end

    test "steering during retry backoff invalidates stale stream and timer events" do
      put_app_env(:generation_auto_retry_backoff_ms, [60_000])
      put_app_env(:generation_auto_retry_jitter_ratio, 0.0)

      fixture =
        generation_fixture!(
          context: [
            test_script: fn
              1 -> [:share_emit, {:error, %{error_text: "First retryable failure"}}]
              _attempt -> [:await]
            end
          ]
        )

      %{worker: worker, monitor: monitor} = gen = start_generation!(fixture)
      message_id = fixture.message.id
      assert_receive {:provider_emit, ^message_id, _provider, stale_emit}
      wait_until(fn -> length(steps!(gen)) == 2 end, 2_000)

      stale_emit.({:trace, {:set_text, "answer", :answer, 1, "Stale retry answer"}})
      stale_emit.({:response_complete, %{raw_response: %{"id" => "stale-retry", "output" => []}}})
      assert %{status: :generating} = Worker.get_current_state(worker)

      queued = enqueue_steer!(gen, "Retry with steering", worker)
      {provider, _request} = await_provider!(gen)
      assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, gen.actor)

      # A stale backoff timer event cannot restart the steered stream.
      send(worker, :retry_current_step)
      assert :sys.get_state(worker).stream_task.pid == provider

      send(provider, {:run, [{:error, %{error_text: "Second retryable failure"}}]})
      wait_until(fn -> length(steps!(gen)) == 4 end, 2_000)
      steps = message!(gen, steps: [items: [:contents]]).steps |> Enum.sort_by(& &1.sequence)
      assert Enum.at(steps, 1).status == :canceled
      assert retry_attempt(Enum.at(steps, 2)) == 2
      refute_provider_started(gen)

      Worker.cancel(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    end
  end

  describe "steering deferred behind persistence" do
    for cancel? <- [false, true] do
      @tag cancel?: cancel?
      test "a queued replacement accounts its deferred response before #{if cancel?, do: "cancellation", else: "dispatch"} of the receiving step",
           %{cancel?: cancel?} do
        fixture = generation_fixture!()
        worker = start_worker!(fixture)
        monitor = Process.monitor(worker)
        {provider, original} = await_provider!(fixture)
        old_stream_ref = :sys.get_state(worker).stream_ref

        queued_handler =
          Barrier.gate_persistence(fixture.message.id,
            queued_steers: :start,
            queued_steers: :stop
          )

        Barrier.gate_persistence(fixture.message.id,
          interrupted_provider: :start,
          interrupted_provider: :stop
        )

        send(worker, :consume_queued_steers)
        writer = Barrier.await_persistence(:queued_steers, :start)
        complete_provider(worker, provider, :tools)
        assert :sys.get_state(worker).deferred_provider_event != nil
        queued = enqueue_steer!(fixture, "Use the receiving request")
        Barrier.release(writer)
        writer = Barrier.await_persistence(:queued_steers, :stop)
        [old_step, next_step] = steps!(fixture)
        assert old_step.status == :canceled
        assert next_step.status == :waiting_provider
        assert :sys.get_state(worker).runtime_step.id == old_step.id
        assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, fixture.actor)
        Barrier.detach(queued_handler)

        cancel_ref =
          if cancel? do
            ref = command(worker, :cancel_and_wait)
            state = :sys.get_state(worker)
            assert state.cancel_requested?
            assert state.runtime_step.output_tokens == 3
            ref
          end

        Barrier.release(writer)
        writer = Barrier.await_persistence(:interrupted_provider, :start)
        assert :sys.get_state(worker).runtime_step.id == next_step.id
        assert_no_dispatch(fixture, worker)
        send_stale_completion(worker, old_stream_ref)
        Barrier.release(writer)
        writer = Barrier.await_persistence(:interrupted_provider, :stop)
        recorded = assert_interrupted_accounting(fixture, original)
        assert_receiving_unaccounted(fixture, next_step.id)
        assert_no_dispatch(fixture, worker)
        if cancel?, do: refute_receive({^cancel_ref, _}, 0)
        Barrier.release(writer)

        if cancel? do
          assert_receive {^cancel_ref, :ok}, 5_000
          assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
          assert message!(fixture).status == :canceled
          assert step!(fixture, next_step.id).status == :canceled
          receiving_request = StepRequests.request_for_step!(next_step.id, actor: fixture.actor)
          assert_receiving_request(fixture, next_step.id, original, receiving_request)
          refute_provider_started(fixture)
        else
          {receiving_provider, receiving_request} = await_provider!(fixture)
          assert_receiving_request(fixture, next_step.id, original, receiving_request)
          send_stale_completion(worker, old_stream_ref)
          finish_receiving_provider(fixture, worker, receiving_provider)
        end

        assert usage!(fixture).id == recorded.id
        assert_interrupted_accounting(fixture, original)
      end
    end

    test "cancel retains usage from a provider event deferred behind a queued-steering read" do
      fixture = generation_fixture!()
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      provider_monitor = Process.monitor(provider)
      Barrier.gate_persistence(fixture.message.id, queued_steers: :start, cancel: :start)
      send(worker, :consume_queued_steers)
      writer = Barrier.await_persistence(:queued_steers, :start)
      send(provider, {:complete, :answer})
      assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :normal}, 5_000
      assert :sys.get_state(worker).deferred_provider_event != nil
      cancel_ref = command(worker, :cancel_and_wait)
      state = :sys.get_state(worker)
      assert state.cancel_requested?
      assert state.runtime_step.output_tokens == 3
      Barrier.release(writer)
      Barrier.release(Barrier.await_persistence(:cancel, :start))
      assert_receive {^cancel_ref, :ok}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert usage!(fixture).output_tokens == 3
      assert message!(fixture).status == :canceled
    end

    test "retry expiration during a queued-steering read is not lost" do
      put_app_env(:generation_auto_retry_backoff_ms, [60_000])
      put_app_env(:generation_auto_retry_jitter_ratio, 0.0)

      fixture = generation_fixture!()
      worker = start_worker!(fixture)
      {provider, _request} = await_provider!(fixture)
      Barrier.gate_persistence(fixture.message.id, auto_retry: :stop, queued_steers: :start)
      send(provider, :retry)
      writer = Barrier.await_persistence(:auto_retry, :stop)
      ref = :sys.get_state(worker).persistence_op.task.ref
      identity = writer.identity

      # Wait for the exact acknowledgment to enter the Worker, then use a system
      # call barrier to observe the installed backoff without timing-dependent polls.
      trace_receives!(worker)
      Barrier.release(writer)

      assert_receive {:trace, ^worker, :receive, {^ref, {:persistence_result, ^identity, _}}},
                     5_000

      assert :sys.get_state(worker).phase == :backoff

      {_timer, retry_token} = :sys.get_state(worker).retry_timer_ref
      send(worker, :consume_queued_steers)
      writer = Barrier.await_persistence(:queued_steers, :start)
      send(worker, {:retry_current_step, retry_token})
      state = :sys.get_state(worker)
      assert state.continuation == :start_stream
      assert state.retry_timer_ref == nil
      Barrier.release(writer)
      Barrier.release(Barrier.await_persistence(:queued_steers, :start))
      await_provider!(fixture)
      cancel_worker!(worker)
    end

    test "steering pending behind a retry commit does not count a second provider attempt" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, auto_retry: :stop)
      worker = start_worker!(fixture)
      {provider, _request} = await_provider!(fixture)
      Barrier.gate_persistence(fixture.message.id, queued_steers: :stop)
      send(provider, :retry)
      writer = Barrier.await_persistence(:auto_retry, :stop)
      queued = enqueue_steer!(fixture, "steer the pending retry", worker)
      Barrier.release(writer)
      writer = Barrier.await_persistence(:queued_steers, :stop)
      assert :sys.get_state(worker).step_attempt == 2
      assert :sys.get_state(worker).stream_task == nil
      refute_provider_started(fixture)
      Barrier.release(writer)
      {_provider, request} = await_provider!(fixture)
      state = :sys.get_state(worker)

      assert {:ok, %{status: :delivered, steering_item_id: steering_item_id}} =
               QueuedMessages.get(queued.id, fixture.actor)

      assert is_integer(steering_item_id)
      assert state.step_attempt == 2
      assert state.step_sequence == 3
      assert Enum.count(request["messages"], &(&1["content"] == "steer the pending retry")) == 1
      cancel_worker!(worker)
    end

    test "a lost queued follow-up ACK installs the committed successor without generation recovery" do
      fixture = generation_fixture!()
      completed = Barrier.gate_persistence(fixture.message.id, provider_completed: :stop)
      followup = Barrier.gate_persistence(fixture.message.id, tool_followup: :stop)
      worker = start_worker!(fixture)
      monitor = Process.monitor(worker)
      {provider, _request} = await_provider!(fixture)
      send(provider, {:complete, :tools})
      writer = Barrier.await_persistence(:provider_completed, :stop)
      queued = enqueue_steer!(fixture, "Queued followup")
      Barrier.detach(completed)
      Barrier.release(writer)
      writer = Barrier.await_persistence(:tool_followup, :stop)
      [source, successor] = steps!(fixture)
      request = StepRequests.request_for_step!(successor.id, actor: fixture.actor)
      assert Enum.count(request["messages"], &(&1["content"] == "Queued followup")) == 1
      assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, fixture.actor)
      Barrier.detach(followup)
      Barrier.crash(writer)

      assert {_provider, ^request} = await_provider!(fixture)
      refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
      assert :sys.get_state(worker).runtime_step.id == successor.id
      assert Enum.map(steps!(fixture), & &1.id) == [source.id, successor.id]
      assert length(Persistence.load_step_for_followup!(source.id).results) == 1
      assert message!(fixture, [:generation_recovery]).generation_recovery == nil
      cancel_worker!(worker)
    end

    test "a queued steer rejection preserves a provider backoff intercepted before its timer starts" do
      put_app_env(:generation_auto_retry_backoff_ms, [60_000])
      put_app_env(:generation_auto_retry_jitter_ratio, 0.0)

      fixture = generation_fixture!(context: [test_reject_steering?: true])
      Barrier.gate_persistence(fixture.message.id, auto_retry: :stop, steering_rejection: :stop)
      worker = start_worker!(fixture)
      {provider, _request} = await_provider!(fixture)
      send(provider, :retry)
      writer = Barrier.await_persistence(:auto_retry, :stop)
      queued = enqueue_steer!(fixture, "Rejected during backoff")
      send(worker, :consume_queued_steers)
      assert :sys.get_state(worker).queue_dirty?
      Barrier.release(writer)
      writer = Barrier.await_persistence(:steering_rejection, :stop)
      state = :sys.get_state(worker)
      assert state.continuation == {:backoff, 60_000}
      assert state.retry_timer_ref == nil

      assert {:ok, %{status: :blocked, blocked_reason: "steering_failed"}} =
               QueuedMessages.get(queued.id, fixture.actor)

      ref = state.persistence_op.task.ref
      identity = writer.identity
      trace_receives!(worker)
      Barrier.release(writer)

      assert_receive {:trace, ^worker, :receive, {^ref, {:persistence_result, ^identity, _}}},
                     5_000

      state = :sys.get_state(worker)
      assert state.phase == :backoff
      {timer, _token} = state.retry_timer_ref
      assert Process.read_timer(timer) > 50_000
      refute_provider_started(fixture)

      # A queued retry sweep must not replace the existing provider timer either.
      handler = Barrier.gate_persistence(fixture.message.id, queued_steers: :stop)
      send(worker, :consume_queued_steers)
      writer = Barrier.await_persistence(:queued_steers, :stop)
      Barrier.detach(handler)
      ref = :sys.get_state(worker).persistence_op.task.ref
      identity = writer.identity
      Barrier.release(writer)

      assert_receive {:trace, ^worker, :receive, {^ref, {:persistence_result, ^identity, _}}},
                     5_000

      assert :sys.get_state(worker).retry_timer_ref == state.retry_timer_ref
      assert Process.read_timer(timer) > 50_000
      refute_provider_started(fixture)
      cancel_worker!(worker)
    end

    test "steering deferred behind a round transition replaces only its receiving step before provider dispatch" do
      fixture = generation_fixture!()
      Barrier.gate_persistence(fixture.message.id, tool_followup: :stop)
      worker = start_worker!(fixture)
      {provider, original} = await_provider!(fixture)
      Barrier.gate_persistence(fixture.message.id, queued_steers: :stop)
      send(provider, {:complete, :tools})
      writer = Barrier.await_persistence(:tool_followup, :stop)
      [old_step, receiving_step] = steps!(fixture)
      receiving_request = StepRequests.request_for_step!(receiving_step.id, actor: fixture.actor)
      queued = enqueue_steer!(fixture, "after round commit", worker)
      Barrier.release(writer)
      writer = Barrier.await_persistence(:queued_steers, :stop)
      refute_provider_started(fixture)
      Barrier.release(writer)
      Barrier.release(Barrier.await_persistence(:queued_steers, :stop))

      {_provider, steered_request} = await_provider!(fixture)
      steered_id = :sys.get_state(worker).runtime_step.id
      assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, fixture.actor)

      assert Enum.count(steered_request["messages"], &(&1["content"] == "after round commit")) ==
               1

      assert :sys.get_state(worker).runtime_step.id == steered_id
      assert StepRequests.request_for_step!(old_step.id, actor: fixture.actor) == original

      assert StepRequests.request_for_step!(receiving_step.id, actor: fixture.actor) ==
               receiving_request

      assert step!(fixture, receiving_step.id).status == :canceled
      cancel_worker!(worker)
    end
  end

  describe "steering failures" do
    for {code, attempts, name} <- [
          {"23514", 1,
           "a check violation leaves the original step, request and provider untouched"},
          {"40001", 4, "a serialization failure exhausts four attempts without terminalizing"},
          {"57P03", 1, "an unavailable database never enters RecoveryGate or replaces the source"}
        ] do
      @tag code: code, attempts: attempts
      test "steering-item rollback: #{name}", %{code: code, attempts: attempts} do
        gen = generation_fixture!() |> start_generation!()
        failure = inject_steering_sql_failure!(gen, code, 100)

        Barrier.gate_persistence(gen.message.id,
          queued_steers: :start,
          steering_reconciliation: :stop
        )

        queued = enqueue_steer!(gen, "Rolled back instruction")
        send(gen.worker, :consume_queued_steers)
        publication = Barrier.await_persistence(:queued_steers, :start)
        assert_original_generation(gen)
        Barrier.release(publication)
        reconciliation = Barrier.await_persistence(:steering_reconciliation, :stop)
        assert_fenced_operation(gen, reconciliation)
        assert sql_attempts(failure) == attempts
        assert_original_generation(gen)

        if code == "57P03" do
          # A retryable failure keeps the steer pending and schedules a worker retry
          # once reconciliation is acknowledged. Cancel while it is still held, so
          # that retry cannot race the cancellation into the gated publication.
          assert {:ok, %{status: :pending, blocked_reason: nil}} =
                   QueuedMessages.get(queued.id, gen.actor)

          assert {:ok, _canceled} = QueuedMessages.cancel(queued.id, gen.actor)
          Barrier.release(reconciliation)
        else
          Barrier.release(reconciliation)
          assert_blocked_steer(gen, queued)
        end

        assert_original_generation(gen)
        assert_one_injection(gen, ["Rolled back instruction"])
        finish_original(gen)
        assert sql_attempts(failure) == attempts
      end
    end

    test "one deadlock retries queued publication only and keeps the old stream until commit acknowledgment" do
      gen = generation_fixture!() |> start_generation!()
      failure = inject_steering_sql_failure!(gen, "40P01", 1)
      Barrier.gate_persistence(gen.message.id, queued_steers: :start, queued_steers: :stop)
      queued = enqueue_steer!(gen, "Committed after deadlock")
      send(gen.worker, :consume_queued_steers)

      publication = Barrier.await_persistence(:queued_steers, :start)
      assert_original_generation(gen)
      Barrier.release(publication)
      publication = Barrier.await_persistence(:queued_steers, :stop)
      assert sql_attempts(failure) == 2
      assert_live_source(gen)
      assert_successor(gen, "Committed after deadlock")
      assert_one_injection(gen, ["Committed after deadlock"])
      assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, gen.actor)
      Barrier.release(publication)

      finish_successor(gen, "Committed after deadlock")
      assert sql_attempts(failure) == 2
    end

    test "a queued rejection blocks only the selected unchanged snapshot and never becomes a follow-up" do
      gen = generation_fixture!(context: [test_reject_steering?: true]) |> start_generation!()
      queued_handler = Barrier.gate_persistence(gen.message.id, queued_steers: :stop)

      Barrier.gate_persistence(gen.message.id,
        steering_reconciliation: :start,
        steering_rejection: :stop
      )

      rejected = enqueue_steer!(gen, "Rejected queued instruction")
      edited = enqueue_steer!(gen, "Selected but subsequently edited")
      send(gen.worker, :consume_queued_steers)
      publication = Barrier.await_persistence(:queued_steers, :stop)

      assert {:ok, _edited} =
               QueuedMessages.update(edited.id, %{content: "A different revision"}, gen.actor)

      later = enqueue_steer!(gen, "Arrived after the failed snapshot")

      assert {:ok, followup} =
               QueuedMessages.enqueue_follow_up(
                 gen.chat.id,
                 %{content: "Unrelated follow-up"},
                 gen.actor
               )

      Barrier.detach(queued_handler)
      Barrier.release(publication)
      reconciliation = Barrier.await_persistence(:steering_reconciliation, :start)
      assert_fenced_operation(gen, reconciliation)
      assert_original_generation(gen)
      Barrier.release(reconciliation)
      rejection = Barrier.await_persistence(:steering_rejection, :stop)
      assert_original_generation(gen)
      assert_blocked_steer(gen, rejected)

      for entry <- [edited, later, followup] do
        assert {:ok, pending} = QueuedMessages.get(entry.id, gen.actor)
        assert pending.status == :pending
        assert pending.blocked_reason == nil
        assert pending.attempt_count == 0
      end

      # These entries are unrelated to the rejected snapshot. Cancel them before
      # releasing the barrier so their legitimate later delivery cannot mask the
      # assertion that the original provider survives this particular rejection.
      for entry <- [edited, later, followup] do
        assert {:ok, _canceled} = QueuedMessages.cancel(entry.id, gen.actor)
      end

      Barrier.release(rejection)
      finish_original(gen)
      assert_blocked_steer(gen, rejected)
      assert {:ok, nil} = QueuedMessages.head_follow_up(gen.chat.id, gen.actor)
      assert {:ok, []} = QueuedMessages.list_pending_steers(gen.message.id, gen.actor)
    end

    for failure <- [:injection, :publication] do
      @tag failure: failure
      test "a queued follow-up #{failure} failure retries preparation without rerunning tools",
           %{failure: failure} do
        tool = web_search_tool!(fn _path, _payload -> {200, %{"web" => %{"results" => []}}} end)

        gen =
          generation_fixture!(
            context: [
              test_reject_steering?: failure == :injection,
              tool_instances_by_alias: %{"web" => tool},
              test_tool_name: "web__web_search",
              test_tool_args: %{"query" => "one execution"}
            ]
          )
          |> start_generation!()

        sql_failure =
          if failure == :publication, do: inject_steering_sql_failure!(gen, "23514", 100)

        completed_handler = Barrier.gate_persistence(gen.message.id, provider_completed: :stop)

        Barrier.gate_persistence(gen.message.id,
          tool_followup: :start,
          steering_reconciliation: :start,
          steering_rejection: :stop
        )

        send(gen.provider, {:complete, :tools})
        completed = Barrier.await_persistence(:provider_completed, :stop)
        queued = enqueue_steer!(gen, "Rejected optional follow-up instruction")
        send(gen.worker, :consume_queued_steers)
        assert :sys.get_state(gen.worker).queue_dirty?
        Barrier.detach(completed_handler)
        Barrier.release(completed)

        assert_receive {:web_request, _path, %{"q" => "one execution"}, _headers}, 5_000
        preparation = Barrier.await_persistence(:tool_followup, :start)
        receipt = assert_tool_receipt(gen)
        Barrier.release(preparation)
        reconciliation = Barrier.await_persistence(:steering_reconciliation, :start)
        assert_fenced_operation(gen, reconciliation)
        assert assert_tool_receipt(gen) == receipt
        Barrier.release(reconciliation)
        rejection = Barrier.await_persistence(:steering_rejection, :stop)
        assert_blocked_steer(gen, queued)
        assert_no_recovery(gen)
        assert assert_tool_receipt(gen) == receipt
        assert items!(gen, :steering) == []
        [source] = steps!(gen)
        assert source.id == gen.step_id
        assert source.status == :waiting_tools

        assert StepRequests.request_for_step!(source.id, actor: gen.actor) ==
                 gen.context.request_payload

        Barrier.release(rejection)

        baseline = Barrier.await_persistence(:tool_followup, :start)
        assert assert_tool_receipt(gen) == receipt
        refute_receive {:web_request, _, _, _}, 0
        Barrier.release(baseline)
        finish_tool_followup(gen, receipt)
        assert_blocked_steer(gen, queued)
        message_id = gen.message.id
        assert_receive {:followup_prepared, ^message_id}, 5_000
        assert_receive {:followup_prepared, ^message_id}, 5_000
        refute_receive {:followup_prepared, ^message_id}, 0
        if sql_failure, do: assert(sql_attempts(sql_failure) == 1)
      end
    end

    for stage <- [:start, :stop] do
      @tag stage: stage
      test "a queued steering ACK lost at #{stage} preserves #{if stage == :start, do: "the old stream", else: "one committed successor"}",
           %{stage: stage} do
        gen = generation_fixture!() |> start_generation!()
        queued_handler = Barrier.gate_persistence(gen.message.id, [{:queued_steers, stage}])

        Barrier.gate_persistence(gen.message.id,
          steering_reconciliation: :start,
          steering_reconciliation: :stop
        )

        queued = enqueue_steer!(gen, "Lost queued ACK")
        send(gen.worker, :consume_queued_steers)
        publication = Barrier.await_persistence(:queued_steers, stage)
        assert_live_source(gen)
        Barrier.detach(queued_handler)
        Barrier.crash(publication)

        reconciliation = Barrier.await_persistence(:steering_reconciliation, :start)
        assert_fenced_operation(gen, reconciliation)
        assert_live_source(gen)
        Barrier.release(reconciliation)
        reconciliation = Barrier.await_persistence(:steering_reconciliation, :stop)
        assert_live_source(gen)
        assert_no_recovery(gen)
        assert {:ok, persisted_queue} = QueuedMessages.get(queued.id, gen.actor)

        if stage == :start do
          assert_original_generation(gen)
          assert persisted_queue.status == :pending
          assert persisted_queue.blocked_reason == nil
          assert persisted_queue.attempt_count == 0
          # Unknown outcome proven not applied remains retryable. Withdraw the
          # command while the read ACK is held, before its intentional queue retry.
          assert {:ok, _canceled} = QueuedMessages.cancel(queued.id, gen.actor)
          Barrier.release(reconciliation)
          finish_original(gen)
        else
          assert persisted_queue.status == :delivered
          [item] = items!(gen, :steering)
          assert persisted_queue.steering_item_id == item.id
          assert items!(gen, :other) == []
          Barrier.release(reconciliation)
          finish_successor(gen, "Lost queued ACK")
          assert {:ok, after_completion} = QueuedMessages.get(queued.id, gen.actor)
          assert after_completion.steering_item_id == item.id
          assert after_completion.status == :delivered
          assert_one_injection(gen, ["Lost queued ACK"])
        end
      end
    end

    test "enqueue validation and queue-only SQL failure do not touch the running provider" do
      gen = generation_fixture!() |> start_generation!()
      assert {:error, _reason} = QueuedMessages.enqueue_steer(gen.message.id, "", gen.actor)
      assert_original_generation(gen)
      inject_sql_failure!("chat_queued_message_contents", "BEFORE INSERT", "TRUE", "23514")

      assert {:error, _reason} =
               QueuedMessages.enqueue_steer(gen.message.id, "Queue write must fail", gen.actor)

      assert {:ok, []} = QueuedMessages.list_pending_steers(gen.message.id, gen.actor)
      assert_original_generation(gen)
      finish_original(gen)
    end
  end

  # Observe the terminal event in the Worker mailbox before sending a command;
  # provider DOWN alone does not order messages sent to two different processes.
  defp complete_provider(worker, provider, completion) do
    stream_ref = :sys.get_state(worker).stream_ref
    trace_receives!(worker)
    send(provider, {:complete, completion})

    assert_receive {:trace, ^worker, :receive,
                    {:provider_event, ^stream_ref, {:response_complete, _meta}}},
                   5_000

    _ = :sys.get_state(worker)
    :erlang.trace(worker, false, [:receive])
  end

  defp assert_no_dispatch(fixture, worker) do
    state = :sys.get_state(worker)
    assert state.phase == :persisting
    assert state.stream_task == nil
    assert state.tool_task == nil
    refute_provider_started(fixture)
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
    step = step!(fixture, nil, [:raw_response, items: [:contents]])
    assert step.status == :canceled
    refute step.response_final
    assert step.raw_response["id"] == "async_response"
    assert StepRequests.request_for_step!(step.id, actor: fixture.actor) == original
    refute Enum.any?(step.items, &(&1.type in [:answer, :tool_call, :tool_result, :artifact]))
    assert Persistence.list_missing_tool_calls!(step.id) == []
    assert Persistence.load_step_for_followup!(step.id).results == []
    recorded = usage!(fixture)
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
    step = step!(fixture, step_id, [:raw_response])
    assert step.status == :waiting_provider
    assert step.raw_response == nil
    assert step.input_tokens == nil
    assert step.output_tokens == nil
    assert step.cost == nil

    assert [] ==
             LlmUsageRecord
             |> Ash.Query.filter(chat_message_step_id_snapshot == ^step_id)
             |> Ash.read!(actor: fixture.actor)
  end

  defp assert_receiving_request(fixture, step_id, original, request) do
    assert request == steered_request(original, "Use the receiving request")
    assert StepRequests.request_for_step!(step_id, actor: fixture.actor) == request
  end

  defp finish_receiving_provider(fixture, worker, provider) do
    monitor = Process.monitor(worker)
    send(provider, {:complete, {:answer, "Receiving answer"}})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert message!(fixture).status == :done
    assert answers!(fixture) == ["Receiving answer"]
    records = usage_records!(fixture)

    assert Enum.map(records, & &1.chat_message_step_id_snapshot) ==
             Enum.map(steps!(fixture), & &1.id)

    assert Enum.map(records, & &1.output_tokens) == [3, 3]
    assert Enum.map(records, & &1.cost) == [0.125, 0.125]
  end

  defp retry_attempt(step) do
    step.items
    |> Enum.flat_map(& &1.contents)
    |> Enum.filter(&(&1.kind == :opaque))
    |> Enum.map(& &1.content_json)
    |> Enum.find_value(fn
      %{"attempt" => attempt, "retryable" => true} -> attempt
      _other -> nil
    end)
  end

  defp inject_steering_sql_failure!(gen, code, failures) do
    inject_sql_failure!(
      "chat_message_items",
      "BEFORE INSERT",
      "NEW.type = 'steering' AND EXISTS (SELECT 1 FROM chat_message_steps " <>
        "WHERE id = NEW.chat_message_step_id AND chat_message_id = #{gen.message.id})",
      code,
      failures
    )
  end

  defp assert_fenced_operation(gen, %Barrier{pid: pid, identity: identity}) do
    assert pid != gen.worker
    assert :sys.get_state(gen.worker).persistence_op.task.pid == pid
    assert identity.kind == :steering_reconciliation
    assert identity.message_id == gen.message.id
    assert identity.step_id == gen.step_id
    assert identity.owner == gen.worker
    assert identity.lease_ref == gen.lease.ref
    assert identity.fence_token == gen.lease.fence_token
    assert identity.lease_manager == gen.lease.manager
  end

  defp assert_live_source(gen) do
    state = :sys.get_state(gen.worker)
    assert state.stream_task.pid == gen.provider
    assert state.stream_ref == gen.initial_state.stream_ref
    assert state.runtime_step.id == gen.step_id
    assert state.runtime_step.raw_request == gen.context.request_payload
    assert state.failure_plan == nil
    assert state.lease.fence_token == gen.lease.fence_token

    %{worker: worker, monitor: monitor, provider: provider, provider_monitor: provider_monitor} =
      gen

    refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
    refute_receive {:DOWN, ^provider_monitor, :process, ^provider, _}, 0
    refute_provider_started(gen)
  end

  defp assert_original_generation(gen) do
    assert_live_source(gen)
    assert_no_recovery(gen)
    [source] = steps!(gen)
    assert source.id == gen.step_id
    assert source.status == :waiting_provider
    refute source.response_final

    assert StepRequests.request_for_step!(source.id, actor: gen.actor) ==
             gen.context.request_payload

    assert items!(gen, :steering) == []
  end

  defp assert_no_recovery(gen, status \\ :generating) do
    message = message!(gen, [:generation_recovery])
    assert message.status == status
    assert message.generation_recovery == nil
    assert message.error_detail == nil
    if status == :generating, do: assert(message.generation_fence_token == gen.lease.fence_token)
  end

  defp assert_successor(gen, instruction) do
    [source, receiving] = steps!(gen)
    assert source.id == gen.step_id
    assert source.status == :canceled
    assert receiving.status == :waiting_provider
    assert receiving.sequence == source.sequence + 1
    assert receiving.id != source.id

    assert StepRequests.request_for_step!(source.id, actor: gen.actor) ==
             gen.context.request_payload

    assert StepRequests.request_for_step!(receiving.id, actor: gen.actor) ==
             steered_request(gen.context.request_payload, instruction)

    [item] = items!(gen, :steering)
    assert item.chat_message_step_id == receiving.id
    receiving
  end

  defp steered_request(request, instruction) do
    Map.update!(request, "messages", &(&1 ++ [%{"role" => "user", "content" => instruction}]))
  end

  defp finish_successor(gen, instruction) do
    {provider, request} = await_provider!(gen)
    assert provider != gen.provider
    assert request == steered_request(gen.context.request_payload, instruction)
    assert :sys.get_state(gen.worker).runtime_step.id == List.last(steps!(gen)).id
    refute_provider_started(gen)
    send(provider, {:complete, {:answer, "Receiving answer"}})
    assert_stopped(gen, :done)
    assert length(steps!(gen)) == 2
    assert length(items!(gen, :steering)) == 1
    assert answers!(gen) == ["Receiving answer"]
    refute_provider_started(gen)
  end

  defp finish_original(gen) do
    send(gen.provider, {:complete, :answer})
    assert_stopped(gen, :done)
    [source] = steps!(gen)
    assert source.id == gen.step_id
    assert source.status == :done

    assert StepRequests.request_for_step!(source.id, actor: gen.actor) ==
             gen.context.request_payload

    assert items!(gen, :steering) == []
    assert answers!(gen) == ["Committed answer"]
    refute_provider_started(gen)
  end

  defp assert_stopped(%{worker: worker, monitor: monitor} = gen, status) do
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert_no_recovery(gen, status)
  end

  defp assert_one_injection(gen, expected) do
    message_id = gen.message.id
    assert_receive {:steering_attempted, ^message_id, ^expected}, 5_000
    refute_receive {:steering_attempted, ^message_id, _}, 0
  end

  defp assert_blocked_steer(gen, queued) do
    assert {:ok, blocked} = QueuedMessages.get(queued.id, gen.actor)
    assert blocked.kind == :steer
    assert blocked.status == :blocked
    assert blocked.blocked_reason == "steering_failed"
    assert blocked.attempt_count == 1
    assert blocked.target_generation_message_id == gen.message.id
    assert blocked.steering_item_id == nil
    assert blocked.user_message_id == nil
    assert blocked.assistant_message_id == nil
    assert blocked.finished_at == nil
    assert QueuedMessages.content_specs(blocked) == QueuedMessages.content_specs(queued)
  end

  defp assert_tool_receipt(gen) do
    assert Persistence.list_missing_tool_calls!(gen.step_id) == []
    [receipt] = Persistence.load_step_for_followup!(gen.step_id).results
    assert receipt.step_id == gen.step_id
    assert receipt.call_id == "call_async"
    [call] = items!(gen, :tool_call)
    assert receipt.tool_call_item_id == call.id
    receipt
  end

  defp finish_tool_followup(gen, receipt) do
    {provider, request} = await_provider!(gen)
    assert provider != gen.provider
    persisted = Persistence.load_step_for_followup!(gen.step_id)
    assert request == ScriptedAdapter.followup_payload(persisted).raw_request
    [source, receiving] = steps!(gen)
    assert source.id == gen.step_id
    assert source.status == :done
    assert receiving.status == :waiting_provider
    assert receiving.sequence == source.sequence + 1

    assert StepRequests.request_for_step!(source.id, actor: gen.actor) ==
             gen.context.request_payload

    assert StepRequests.request_for_step!(receiving.id, actor: gen.actor) == request
    assert assert_tool_receipt(gen) == receipt
    refute_provider_started(gen)
    refute_receive {:web_request, _, _, _}, 0
    send(provider, {:complete, {:answer, "Follow-up answer"}})
    assert_stopped(gen, :done)
    assert length(steps!(gen)) == 2
    assert assert_tool_receipt(gen) == receipt
    assert answers!(gen) == ["Follow-up answer"]
    refute_provider_started(gen)
    refute_receive {:web_request, _, _, _}, 0
  end
end
