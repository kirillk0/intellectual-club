defmodule IntellectualClub.Generation.SteeringFailureWorkerTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageItem,
    ChatMessageStep,
    QueuedMessages
  }

  alias IntellectualClub.Generation.{Lease, Persistence, StepRequests, Worker}
  alias IntellectualClub.Test.{AsyncPersistenceAdapter, SteeringFailureAdapter}
  alias IntellectualClub.TestSupport.WebSearchServer
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @event [:intellectual_club, :generation, :persistence]

  test "23514 steering-item rollback leaves the original step, request and provider untouched" do
    assert_provider_rollback("23514", 1)
  end

  test "40001 exhausts four transaction attempts without terminalizing the generation" do
    assert_provider_rollback("40001", 4)
  end

  test "57P03 rolled-back steering never enters RecoveryGate or replaces the source step" do
    assert_provider_rollback("57P03", 1)
  end

  test "one deadlock retries queued publication only and keeps the old stream until commit acknowledgment" do
    fixture = fixture() |> start_worker()
    inject_steering_sql_failure(fixture, "40P01", 1)
    gate_operations(fixture, queued_steers: :start, queued_steers: :stop)
    queued = enqueue_steer(fixture, "Committed after deadlock")
    send(fixture.worker, :consume_queued_steers)

    publication = await_barrier(:queued_steers, :start)
    assert_original_generation(fixture)
    release(publication)
    publication = await_barrier(:queued_steers, :stop)
    assert sql_attempts() == 2
    assert_live_source(fixture)
    assert_successor(fixture, "Committed after deadlock")
    assert_one_injection(fixture, ["Committed after deadlock"])
    assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, fixture.actor)
    release(publication)

    finish_successor(fixture, "Committed after deadlock")
    assert sql_attempts() == 2
  end

  test "queued rejection blocks only the selected unchanged snapshot and never becomes a follow-up" do
    fixture = fixture(test_reject_steering?: true) |> start_worker()
    queued_handler = gate_operations(fixture, queued_steers: :stop)
    gate_operations(fixture, steering_reconciliation: :start, steering_rejection: :stop)
    rejected = enqueue_steer(fixture, "Rejected queued instruction")
    edited = enqueue_steer(fixture, "Selected but subsequently edited")
    send(fixture.worker, :consume_queued_steers)
    publication = await_barrier(:queued_steers, :stop)

    assert {:ok, _edited} =
             QueuedMessages.update(edited.id, %{content: "A different revision"}, fixture.actor)

    later = enqueue_steer(fixture, "Arrived after the failed snapshot")

    assert {:ok, followup} =
             QueuedMessages.enqueue_follow_up(
               fixture.chat.id,
               %{content: "Unrelated follow-up"},
               fixture.actor
             )

    :telemetry.detach(queued_handler)
    release(publication)
    reconciliation = await_barrier(:steering_reconciliation, :start)
    assert_fenced_operation(fixture, reconciliation)
    assert_original_generation(fixture)
    release(reconciliation)
    rejection = await_barrier(:steering_rejection, :stop)
    assert_original_generation(fixture)
    assert_blocked_steer(fixture, rejected)

    for entry <- [edited, later, followup] do
      assert {:ok, pending} = QueuedMessages.get(entry.id, fixture.actor)
      assert pending.status == :pending
      assert pending.blocked_reason == nil
      assert pending.attempt_count == 0
    end

    # These entries are unrelated to the rejected snapshot. Cancel them before
    # releasing the barrier so their legitimate later delivery cannot mask the
    # assertion that the original provider survives this particular rejection.
    for entry <- [edited, later, followup] do
      assert {:ok, _canceled} = QueuedMessages.cancel(entry.id, fixture.actor)
    end

    release(rejection)
    finish_original(fixture)
    assert_blocked_steer(fixture, rejected)
    assert {:ok, nil} = QueuedMessages.head_follow_up(fixture.chat.id, fixture.actor)
    assert {:ok, []} = QueuedMessages.list_pending_steers(fixture.message.id, fixture.actor)
  end

  test "queued follow-up injection or publication failure retries preparation without rerunning tools" do
    for failure <- [:injection, :publication] do
      fixture =
        fixture(test_reject_steering?: failure == :injection)
        |> with_web_tool()
        |> start_worker()

      if failure == :publication, do: inject_steering_sql_failure(fixture, "23514", 100)
      completed_handler = gate_operations(fixture, provider_completed: :stop)

      gate_operations(fixture,
        tool_followup: :start,
        steering_reconciliation: :start,
        steering_rejection: :stop
      )

      send(fixture.provider, {:complete, :tools})
      completed = await_barrier(:provider_completed, :stop)
      queued = enqueue_steer(fixture, "Rejected optional follow-up instruction")
      send(fixture.worker, :consume_queued_steers)
      assert :sys.get_state(fixture.worker).queue_dirty?
      :telemetry.detach(completed_handler)
      release(completed)

      assert_web_tool_called()
      preparation = await_barrier(:tool_followup, :start)
      receipt = assert_tool_receipt(fixture)
      release(preparation)
      reconciliation = await_barrier(:steering_reconciliation, :start)
      assert_fenced_operation(fixture, reconciliation)
      assert_tool_receipt_unchanged(fixture, receipt)
      release(reconciliation)
      rejection = await_barrier(:steering_rejection, :stop)
      assert_blocked_steer(fixture, queued)
      assert_no_recovery(fixture)
      assert_tool_receipt_unchanged(fixture, receipt)
      assert steering_items(fixture) == []
      [source] = steps(fixture)
      assert source.id == fixture.step_id
      assert source.status == :waiting_tools

      assert StepRequests.request_for_step!(source.id, actor: fixture.actor) ==
               fixture.context.request_payload

      release(rejection)

      baseline = await_barrier(:tool_followup, :start)
      assert_tool_receipt_unchanged(fixture, receipt)
      refute_receive {:web_request, _, _, _}, 0
      release(baseline)
      finish_tool_followup(fixture, receipt)
      assert_blocked_steer(fixture, queued)
      message_id = fixture.message.id
      assert_receive {:followup_prepared, ^message_id}, 2_000
      assert_receive {:followup_prepared, ^message_id}, 2_000
      refute_receive {:followup_prepared, ^message_id}, 0
      if failure == :publication, do: assert(sql_attempts() == 1)
    end
  end

  test "lost queued steering ACK preserves either the old stream or one committed successor" do
    for stage <- [:start, :stop] do
      fixture = fixture() |> start_worker()
      queued_handler = gate_operations(fixture, [{:queued_steers, stage}])
      gate_operations(fixture, steering_reconciliation: :start, steering_reconciliation: :stop)
      queued = enqueue_steer(fixture, "Lost queued ACK")
      send(fixture.worker, :consume_queued_steers)
      publication = await_barrier(:queued_steers, stage)
      assert_live_source(fixture)
      :telemetry.detach(queued_handler)
      crash_at_boundary(publication)

      reconciliation = await_barrier(:steering_reconciliation, :start)
      assert_fenced_operation(fixture, reconciliation)
      assert_live_source(fixture)
      release(reconciliation)
      reconciliation = await_barrier(:steering_reconciliation, :stop)
      assert_live_source(fixture)
      assert_no_recovery(fixture)
      assert {:ok, persisted_queue} = QueuedMessages.get(queued.id, fixture.actor)

      if stage == :start do
        assert_original_generation(fixture)
        assert persisted_queue.status == :pending
        assert persisted_queue.blocked_reason == nil
        assert persisted_queue.attempt_count == 0
        # Unknown outcome proven not applied remains retryable. Withdraw the
        # command while the read ACK is held, before its intentional queue retry.
        assert {:ok, _canceled} = QueuedMessages.cancel(queued.id, fixture.actor)
        release(reconciliation)
        finish_original(fixture)
      else
        assert persisted_queue.status == :delivered
        [item] = steering_items(fixture)
        assert persisted_queue.steering_item_id == item.id
        assert items(fixture, :other) == []
        release(reconciliation)
        finish_successor(fixture, "Lost queued ACK")
        assert {:ok, after_completion} = QueuedMessages.get(queued.id, fixture.actor)
        assert after_completion.steering_item_id == item.id
        assert after_completion.status == :delivered
        assert_one_injection(fixture, ["Lost queued ACK"])
      end
    end
  end

  test "enqueue validation and queue-only SQL failure do not touch the running provider" do
    fixture = fixture() |> start_worker()
    assert {:error, _reason} = QueuedMessages.enqueue_steer(fixture.message.id, "", fixture.actor)
    assert_original_generation(fixture)
    inject_enqueue_sql_failure()

    assert {:error, _reason} =
             QueuedMessages.enqueue_steer(
               fixture.message.id,
               "Queue write must fail",
               fixture.actor
             )

    assert {:ok, []} = QueuedMessages.list_pending_steers(fixture.message.id, fixture.actor)
    assert_original_generation(fixture)
    finish_original(fixture)
  end

  # These callbacks execute outside the operation's SQL checkout. Killing a
  # task here models a lost ACK without destroying the sandbox ownership proxy.
  def persistence_barrier(event, _measurements, metadata, {owner, message_id, gates}) do
    stage = List.last(event)

    if metadata.message_id == message_id and {metadata.kind, stage} in gates do
      token = make_ref()
      monitor = Process.monitor(owner)
      send(owner, {:steering_barrier, metadata.kind, stage, self(), metadata, token})

      try do
        receive do
          {^token, :continue} -> :ok
          {^token, :crash} -> Process.exit(self(), :kill)
          {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  defp gate_operations(fixture, gates) do
    handler = {__MODULE__, fixture.message.id, make_ref()}

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

  defp await_barrier(kind, stage) do
    assert_receive {:steering_barrier, ^kind, ^stage, pid, identity, token}, 5_000
    %{pid: pid, identity: identity, token: token}
  end

  defp release(%{pid: pid, token: token}), do: send(pid, {token, :continue})

  defp crash_at_boundary(%{pid: pid, token: token}) do
    monitor = Process.monitor(pid)
    send(pid, {token, :crash})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
  end

  defp assert_provider_rollback(code, attempts) do
    fixture = fixture() |> start_worker()
    inject_steering_sql_failure(fixture, code, 100)
    gate_operations(fixture, queued_steers: :start, steering_reconciliation: :stop)
    queued = enqueue_steer(fixture, "Rolled back instruction")
    send(fixture.worker, :consume_queued_steers)
    publication = await_barrier(:queued_steers, :start)
    assert_original_generation(fixture)
    release(publication)
    reconciliation = await_barrier(:steering_reconciliation, :stop)
    assert_fenced_operation(fixture, reconciliation)
    assert sql_attempts() == attempts
    assert_original_generation(fixture)
    release(reconciliation)

    if code == "57P03" do
      assert {:ok, %{status: :pending, blocked_reason: nil}} =
               QueuedMessages.get(queued.id, fixture.actor)

      assert {:ok, _canceled} = QueuedMessages.cancel(queued.id, fixture.actor)
    else
      assert_blocked_steer(fixture, queued)
    end

    assert_original_generation(fixture)
    assert_one_injection(fixture, ["Rolled back instruction"])
    finish_original(fixture)
    assert sql_attempts() == attempts
  end

  defp assert_fenced_operation(fixture, %{pid: pid, identity: identity}) do
    assert pid != fixture.worker
    assert :sys.get_state(fixture.worker).persistence_op.task.pid == pid
    assert identity.kind == :steering_reconciliation
    assert identity.message_id == fixture.message.id
    assert identity.step_id == fixture.step_id
    assert identity.owner == fixture.worker
    assert identity.lease_ref == fixture.lease.ref
    assert identity.fence_token == fixture.lease.fence_token
    assert identity.lease_manager == fixture.lease.manager
  end

  defp assert_live_source(fixture) do
    state = :sys.get_state(fixture.worker)
    assert state.stream_task.pid == fixture.provider
    assert state.stream_ref == fixture.initial_state.stream_ref
    assert state.runtime_step.id == fixture.step_id
    assert state.runtime_step.raw_request == fixture.context.request_payload
    assert state.failure_plan == nil
    assert state.lease.fence_token == fixture.lease.fence_token
    worker = fixture.worker
    monitor = fixture.monitor
    provider = fixture.provider
    provider_monitor = fixture.provider_monitor
    refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
    refute_receive {:DOWN, ^provider_monitor, :process, ^provider, _}, 0
    assert_no_new_provider(fixture)
  end

  defp assert_original_generation(fixture) do
    assert_live_source(fixture)
    assert_no_recovery(fixture)
    [source] = steps(fixture)
    assert source.id == fixture.step_id
    assert source.status == :waiting_provider
    refute source.response_final

    assert StepRequests.request_for_step!(source.id, actor: fixture.actor) ==
             fixture.context.request_payload

    assert steering_items(fixture) == []
  end

  defp assert_no_recovery(fixture, status \\ :generating) do
    message =
      Ash.get!(ChatMessage, fixture.message.id,
        actor: fixture.actor,
        load: [:generation_recovery]
      )

    assert message.status == status
    assert message.generation_recovery == nil
    assert message.error_detail == nil

    if status == :generating do
      assert message.generation_fence_token == fixture.lease.fence_token
    end
  end

  defp assert_successor(fixture, instruction) do
    [source, receiving] = steps(fixture)
    assert source.id == fixture.step_id
    assert source.status == :canceled
    assert receiving.status == :waiting_provider
    assert receiving.sequence == source.sequence + 1
    assert receiving.id != source.id

    assert StepRequests.request_for_step!(source.id, actor: fixture.actor) ==
             fixture.context.request_payload

    assert StepRequests.request_for_step!(receiving.id, actor: fixture.actor) ==
             steered_request(fixture, instruction)

    [item] = steering_items(fixture)
    assert item.chat_message_step_id == receiving.id
    receiving
  end

  defp steered_request(fixture, instruction) do
    Map.update!(fixture.context.request_payload, "messages", fn messages ->
      messages ++ [%{"role" => "user", "content" => instruction}]
    end)
  end

  defp finish_successor(fixture, instruction) do
    message_id = fixture.message.id
    assert_receive {:provider_started, ^message_id, provider, request}, 5_000
    assert provider != fixture.provider
    assert request == steered_request(fixture, instruction)
    assert :sys.get_state(fixture.worker).runtime_step.id == List.last(steps(fixture)).id
    assert_no_new_provider(fixture)
    send(provider, {:complete, {:answer, "Receiving answer"}})
    assert_stopped(fixture, :done)
    assert length(steps(fixture)) == 2
    assert length(steering_items(fixture)) == 1
    assert_answer(fixture, "Receiving answer")
    assert_no_new_provider(fixture)
  end

  defp finish_original(fixture) do
    send(fixture.provider, {:complete, :answer})
    assert_stopped(fixture, :done)
    [source] = steps(fixture)
    assert source.id == fixture.step_id
    assert source.status == :done

    assert StepRequests.request_for_step!(source.id, actor: fixture.actor) ==
             fixture.context.request_payload

    assert steering_items(fixture) == []
    assert_answer(fixture, "Committed answer")
    assert_no_new_provider(fixture)
  end

  defp assert_stopped(fixture, status) do
    worker = fixture.worker
    monitor = fixture.monitor
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000

    if status == :canceled do
      message =
        Ash.get!(ChatMessage, fixture.message.id,
          actor: fixture.actor,
          load: [:generation_recovery]
        )

      assert message.status == :canceled
      assert message.generation_recovery["operation"] == "cancel"
      assert message.generation_recovery["terminal_status"] == "canceled"
    else
      assert_no_recovery(fixture, status)
    end
  end

  defp assert_no_new_provider(fixture) do
    message_id = fixture.message.id
    refute_receive {:provider_started, ^message_id, _, _}, 0
  end

  defp assert_answer(fixture, expected) do
    answers =
      fixture
      |> items(:answer)
      |> Enum.flat_map(& &1.contents)
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.map(& &1.content_text)

    assert answers == [expected]
  end

  defp assert_one_injection(fixture, expected) do
    message_id = fixture.message.id
    assert_receive {:steering_attempted, ^message_id, ^expected}, 2_000
    refute_receive {:steering_attempted, ^message_id, _}, 0
  end

  defp enqueue_steer(fixture, text) do
    assert {:ok, queued} = QueuedMessages.enqueue_steer(fixture.message.id, text, fixture.actor)
    queued
  end

  defp assert_blocked_steer(fixture, queued) do
    assert {:ok, blocked} = QueuedMessages.get(queued.id, fixture.actor)
    assert blocked.kind == :steer
    assert blocked.status == :blocked
    assert blocked.blocked_reason == "steering_failed"
    assert blocked.attempt_count == 1
    assert blocked.target_generation_message_id == fixture.message.id
    assert blocked.steering_item_id == nil
    assert blocked.user_message_id == nil
    assert blocked.assistant_message_id == nil
    assert blocked.finished_at == nil
    assert QueuedMessages.content_specs(blocked) == QueuedMessages.content_specs(queued)
  end

  defp assert_web_tool_called do
    assert_receive {:web_request, _path, %{"q" => "one execution"}, _headers}, 5_000
  end

  defp assert_tool_receipt(fixture) do
    assert Persistence.list_missing_tool_calls!(fixture.step_id) == []
    [receipt] = Persistence.load_step_for_followup!(fixture.step_id).results
    assert receipt.step_id == fixture.step_id
    assert receipt.call_id == "call_async"
    [call] = items(fixture, :tool_call)
    assert receipt.tool_call_item_id == call.id
    receipt
  end

  defp assert_tool_receipt_unchanged(fixture, receipt) do
    assert assert_tool_receipt(fixture) == receipt
  end

  defp finish_tool_followup(fixture, receipt, instruction \\ nil) do
    message_id = fixture.message.id
    assert_receive {:provider_started, ^message_id, provider, request}, 5_000
    assert provider != fixture.provider
    persisted = Persistence.load_step_for_followup!(fixture.step_id)
    baseline = AsyncPersistenceAdapter.build_followup_request(persisted).raw_request

    expected =
      if instruction do
        Map.update!(
          baseline,
          "messages",
          &(&1 ++ [%{"role" => "user", "content" => instruction}])
        )
      else
        baseline
      end

    assert request == expected
    [source, receiving] = steps(fixture)
    assert source.id == fixture.step_id
    assert source.status == :done
    assert receiving.status == :waiting_provider
    assert receiving.sequence == source.sequence + 1

    assert StepRequests.request_for_step!(source.id, actor: fixture.actor) ==
             fixture.context.request_payload

    assert StepRequests.request_for_step!(receiving.id, actor: fixture.actor) == request
    assert_tool_receipt_unchanged(fixture, receipt)
    assert_no_new_provider(fixture)
    refute_receive {:web_request, _, _, _}, 0
    send(provider, {:complete, {:answer, "Follow-up answer"}})
    assert_stopped(fixture, :done)
    assert length(steps(fixture)) == 2
    assert_tool_receipt_unchanged(fixture, receipt)
    assert_answer(fixture, "Follow-up answer")
    assert_no_new_provider(fixture)
    refute_receive {:web_request, _, _, _}, 0
  end

  # nextval survives rollback, so this counts real transaction attempts rather
  # than adapter calls. All sequence/function/trigger DDL is sandbox-local.
  defp inject_steering_sql_failure(fixture, code, failures) do
    Repo.query!("CREATE TEMP SEQUENCE steering_failure_attempts")

    Repo.query!("""
    CREATE FUNCTION pg_temp.fail_steering_publication() RETURNS trigger AS $$
    BEGIN
      IF NEW.type = 'steering' AND EXISTS (
        SELECT 1 FROM chat_message_steps
        WHERE id = NEW.chat_message_step_id AND chat_message_id = #{fixture.message.id}
      ) THEN
        IF nextval('pg_temp.steering_failure_attempts') <= #{failures} THEN
          RAISE EXCEPTION 'Injected steering publication failure' USING ERRCODE = '#{code}';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_steering_publication_failure BEFORE INSERT ON chat_message_items
    FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_steering_publication()
    """)
  end

  defp sql_attempts do
    %{rows: [[attempts]]} =
      Repo.query!("SELECT last_value FROM pg_temp.steering_failure_attempts")

    attempts
  end

  defp inject_enqueue_sql_failure do
    Repo.query!("""
    CREATE FUNCTION pg_temp.fail_steering_enqueue() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'Injected queue-only failure' USING ERRCODE = '23514';
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_steering_enqueue_failure BEFORE INSERT ON chat_queued_message_contents
    FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_steering_enqueue()
    """)
  end

  defp fixture(overrides \\ []) do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(:create_generating_assistant, %{chat_id: chat.id}, actor: actor)
      |> Ash.create!(actor: actor)

    request = %{
      "model" => "test",
      "messages" => [%{"role" => "user", "content" => "Original request"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(message.id, request)

    context =
      Map.merge(
        %{
          owner_id: actor.id,
          chat_id: chat.id,
          message_id: message.id,
          step_id: step_id,
          adapter_module: SteeringFailureAdapter,
          provider_type: "test",
          request_payload: request,
          timeout_ms: 5_000,
          chunk_delay_ms: 0,
          test_pid: self(),
          tool_instances_by_alias: %{},
          max_tool_rounds: 8,
          tools_payload: []
        },
        Map.new(overrides)
      )

    %{actor: actor, chat: chat, message: message, step_id: step_id, context: context}
  end

  defp with_web_tool(fixture) do
    owner = self()

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug:
             {WebSearchServer,
              handler: fn _path, _payload -> {200, %{"web" => %{"results" => []}}} end,
              test_pid: owner},
           scheme: :http,
           port: 0},
          id: {:steering_web_tool, fixture.message.id}
        )
      )

    {:ok, {_host, port}} = ThousandIsland.listener_info(server)

    tool = %ToolInstance{
      type: "native-web-search",
      config: %{
        "providers" => ["brave"],
        "provider_options" => %{
          "brave" => %{"api_base_url" => "http://127.0.0.1:#{port}/brave"}
        }
      },
      secrets: %{"brave_api_key" => "test-key"}
    }

    context =
      Map.merge(fixture.context, %{
        tool_instances_by_alias: %{"web" => tool},
        test_tool_name: "web__web_search",
        test_tool_args: %{"query" => "one execution"}
      })

    %{fixture | context: context}
  end

  defp start_worker(fixture) do
    assert {:ok, lease} = Lease.acquire(fixture.message.id)

    worker =
      start_supervised!(%{
        id: {Worker, fixture.message.id},
        start:
          {Worker, :start_link, [%{context: fixture.context, lease: lease, lease_owner: self()}]},
        restart: :temporary
      })

    monitor = Process.monitor(worker)
    message_id = fixture.message.id
    assert_receive {:provider_started, ^message_id, provider, request}, 5_000
    assert request == fixture.context.request_payload

    Map.merge(fixture, %{
      worker: worker,
      monitor: monitor,
      provider: provider,
      provider_monitor: Process.monitor(provider),
      initial_state: :sys.get_state(worker),
      lease: lease
    })
  end

  defp steps(fixture) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^fixture.message.id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: fixture.actor)
  end

  defp steering_items(fixture), do: items(fixture, :steering)

  defp items(fixture, type) do
    step_ids = Enum.map(steps(fixture), & &1.id)

    ChatMessageItem
    |> Ash.Query.filter(chat_message_step_id in ^step_ids and type == ^type)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:contents)
    |> Ash.read!(actor: fixture.actor)
  end
end
