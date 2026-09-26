defmodule IntellectualClub.Generation.PersistenceFailureWorkerTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep}
  alias IntellectualClub.Generation.{Lease, Persistence, StepRequests, Worker}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Test.{AsyncPersistenceAdapter, FailingFollowupAdapter}

  require Ash.Query

  test "permanent follow-up failure terminalizes and cannot be revived by recovery" do
    fixture = fixture(FailingFollowupAdapter)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, original}, 2_000
    send(provider, {:complete, :tools})
    assert_receive :followup_attempted, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000

    message =
      Ash.get!(ChatMessage, fixture.message.id,
        actor: fixture.actor,
        load: [:generation_recovery]
      )

    assert message.status == :error
    assert message.error_detail =~ "tool_followup"
    assert message.error_detail =~ "ArgumentError"
    assert StepRequests.request_for_step!(fixture.step_id, actor: fixture.actor) == original
    assert length(Persistence.load_step_for_followup!(fixture.step_id).results) == 1

    for _ <- 1..4 do
      assert {:error, :invalid_status} =
               GenerationSupervisor.resume_orphaned_message(message.id, actor: fixture.actor)
    end

    refute_receive :followup_attempted, 0
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "deadlock retries only the provider persistence transaction" do
    fixture = fixture()
    inject_sql_failure(fixture, "40P01", 1)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :answer})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :done
    assert sql_attempts() == 2
    assert length(steps(fixture)) == 1
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "persistent rollback failure exhausts its database budget and becomes visible" do
    fixture = fixture()
    inject_sql_failure(fixture, "40001", 100)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :answer})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 8_000

    message =
      Ash.get!(ChatMessage, fixture.message.id,
        actor: fixture.actor,
        load: [:generation_recovery]
      )

    assert message.status == :error
    assert message.error_detail =~ "provider_completed"
    assert message.error_detail =~ "4 database attempts"
    assert sql_attempts() == 4

    assert {:error, :invalid_status} =
             GenerationSupervisor.resume_orphaned_message(message.id, actor: fixture.actor)

    refute_receive {:provider_started, _, _, _}, 0
  end

  test "ordinary SQL validation error does not retry as a deadlock" do
    fixture = fixture()
    inject_sql_failure(fixture, "23514", 100)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :answer})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :error
    assert sql_attempts() == 1
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "database unavailability during finalization retries only the durable terminal intent" do
    fixture = fixture(FailingFollowupAdapter)
    inject_finish_failure(fixture, "57P03", 1)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive :followup_attempted, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000

    message =
      Ash.get!(ChatMessage, fixture.message.id,
        actor: fixture.actor,
        load: [:generation_recovery]
      )

    assert message.status == :error
    assert message.generation_recovery["terminal_status"] == "error"
    assert sql_attempts() == 2
    refute_receive :followup_attempted, 0
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "terminal finalization retains its writer until acknowledgement across lease validation" do
    fixture = fixture(FailingFollowupAdapter)
    inject_finish_failure(fixture, "57P03", 1)
    manager = Process.whereis(Lease)
    gate = make_ref()
    handler = {__MODULE__, gate}

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :generation, :persistence, :stop],
        &__MODULE__.terminal_ack_barrier/4,
        {self(), fixture.message.id, gate}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000

    # Run validation after the terminal write, but before the result reaches
    # the Worker. This is the periodic validator's otherwise timing-only race.
    :ok = :sys.suspend(manager)

    try do
      send(provider, {:complete, :tools})
      assert_receive :followup_attempted, 2_000
      assert_receive {:terminal_persistence_returned, writer}, 5_000
      writer_monitor = Process.monitor(writer)

      try do
        assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :error
        assert sql_attempts() == 2
        :ok = Lease.trigger_validation()
        :ok = :sys.resume(manager)
        _ = :sys.get_state(manager)

        assert %{persistence_op: %{task: %{pid: ^writer}}} = :sys.get_state(worker)
        send(writer, {gate, :continue})
        assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 5_000
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
        assert Process.whereis(Lease) == manager

        assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).generation_fence_token ==
                 nil

        refute_receive :followup_attempted, 0
        refute_receive {:provider_started, _, _, _}, 0
      after
        send(writer, {gate, :continue})
      end
    after
      :sys.resume(manager)
      :telemetry.detach(handler)
    end
  end

  test "an outage before intent commit outlives three retries without losing terminal intent" do
    fixture = fixture(FailingFollowupAdapter)
    inject_intent_outage(fixture, 4)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    :erlang.trace(worker, true, [:receive])
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive :followup_attempted, 2_000

    for attempt <- 1..4 do
      assert_receive {:trace, ^worker, :receive,
                      {_ref,
                       {:persistence_result, %{kind: :failure_resolution}, {:error, _failure}}}},
                     2_000

      state = :sys.get_state(worker)
      assert state.failure_plan.attempt == attempt
      assert state.failure_plan.terminal_status == :error
      assert state.phase == :recovering

      message =
        Ash.get!(ChatMessage, fixture.message.id,
          actor: fixture.actor,
          load: [:generation_recovery]
        )

      assert message.generation_recovery == nil
      refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
      {timer, token} = state.failure_retry_timer
      Process.cancel_timer(timer)
      Worker.queue_changed(worker)
      send(worker, :consume_queued_steers)
      assert :sys.get_state(worker).persistence_op == nil
      send(worker, {:retry_failure_resolution, token})
    end

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 3_000
    assert sql_attempts() == 5
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :error
    refute_receive :followup_attempted, 0
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "a permanently failing finalizer releases its Worker but never resumes external work" do
    fixture = fixture(FailingFollowupAdapter)
    inject_finish_failure(fixture, "23514", 100)
    worker = start_worker(fixture)
    monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 2_000
    send(provider, {:complete, :tools})
    assert_receive :followup_attempted, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert sql_attempts() == 3

    message =
      Ash.get!(ChatMessage, fixture.message.id,
        actor: fixture.actor,
        load: [:generation_recovery]
      )

    assert message.status == :generating
    assert message.generation_recovery["terminal_status"] == "error"

    assert {:error, _} =
             GenerationSupervisor.resume_orphaned_message(message.id, actor: fixture.actor)

    assert GenerationSupervisor.generation_worker_pid(message.id) == nil
    assert sql_attempts() == 4

    Repo.query!("DROP TRIGGER test_error_finalization_failure ON chat_messages")

    assert {:ok, %{status: :error, recovery_finished?: true}} =
             GenerationSupervisor.resume_orphaned_message(message.id, actor: fixture.actor)

    assert Ash.get!(ChatMessage, message.id, actor: fixture.actor).status == :error
    refute_receive :followup_attempted, 0
    refute_receive {:provider_started, _, _, _}, 0
  end

  test "a post-commit SQL error in notifications never replays the committed write" do
    fixture = fixture()
    Process.put(:publication_count, 0)

    assert {:error, failure} =
             IntellectualClub.Generation.PersistenceFailure.capture(
               fn ->
                 IntellectualClub.Generation.PersistenceFailure.ash_transaction(ChatMessage, fn ->
                   Process.put(:publication_count, Process.get(:publication_count) + 1)

                   fixture.message
                   |> Ash.Changeset.for_update(:update_token_count, %{token_count: 42},
                     actor: fixture.actor
                   )
                   |> Ash.update!(actor: fixture.actor)

                   notification = %Ash.Notifier.Notification{
                     resource: ChatMessage,
                     action: Ash.Resource.Info.action(ChatMessage, :update_token_count),
                     for: IntellectualClub.Test.FailingPersistenceNotifier,
                     metadata: %{test: self()}
                   }

                   Process.put(:ash_notifications, [
                     notification | Process.get(:ash_notifications, [])
                   ])

                   :committed
                 end)
               end,
               :done
             )

    assert failure.kind == :unknown
    assert failure.operation == :post_commit_notifications
    assert Process.get(:publication_count) == 1
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).token_count == 42
    assert_receive :post_commit_notification
    refute_receive :post_commit_notification, 0
  end

  test "a nested transaction leaves retry to the outer transaction owner" do
    Process.put(:nested_attempts, 0)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        IntellectualClub.Generation.PersistenceFailure.transaction(
          fn ->
            Process.put(:nested_attempts, Process.get(:nested_attempts) + 1)

            raise %Postgrex.Error{
              message: "Injected serialization failure",
              postgres: %{
                code: :serialization_failure,
                pg_code: "40001",
                severity: "ERROR",
                message: "Injected serialization failure"
              }
            }
          end,
          delays: [0, 0, 0]
        )
      end)
    end

    assert Process.get(:nested_attempts) == 1
  end

  # The operation has returned its SQL connection, but its owner has not yet
  # received the persistence result. Validation must not kill that result.
  def terminal_ack_barrier(
        _event,
        _measurements,
        %{kind: :failure_resolution, message_id: message_id, outcome: :ok},
        {test, message_id, gate}
      ) do
    monitor = Process.monitor(test)
    send(test, {:terminal_persistence_returned, self()})

    try do
      receive do
        {^gate, :continue} -> :ok
        {:DOWN, ^monitor, :process, ^test, _reason} -> :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def terminal_ack_barrier(_event, _measurements, _metadata, _config), do: :ok

  # The trigger runs inside the real fenced transaction. nextval is deliberately
  # nontransactional, so an actual rollback cannot reset the injection counter.
  # The sandbox rolls back all trigger/function/sequence DDL at fixture cleanup.
  defp inject_sql_failure(fixture, code, count) do
    Repo.query!("CREATE TEMP SEQUENCE persistence_failure_attempts")

    Repo.query!("""
    CREATE FUNCTION pg_temp.fail_provider_persistence() RETURNS trigger AS $$
    BEGIN
      IF NEW.id = #{fixture.step_id} AND NOT OLD.response_final AND NEW.response_final THEN
        IF nextval('pg_temp.persistence_failure_attempts') <= #{count} THEN
          RAISE EXCEPTION 'Injected provider persistence failure' USING ERRCODE = '#{code}';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_provider_persistence_failure BEFORE UPDATE ON chat_message_steps
    FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_provider_persistence()
    """)
  end

  defp inject_intent_outage(fixture, count) do
    Repo.query!("CREATE TEMP SEQUENCE persistence_failure_attempts")

    Repo.query!("""
    CREATE FUNCTION pg_temp.fail_error_intent() RETURNS trigger AS $$
    BEGIN
      IF NEW.id = #{fixture.message.id} AND NEW.generation_recovery IS DISTINCT FROM OLD.generation_recovery THEN
        IF nextval('pg_temp.persistence_failure_attempts') <= #{count} THEN
          RAISE EXCEPTION 'Injected intent outage' USING ERRCODE = '57P03';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_error_intent_outage BEFORE UPDATE ON chat_messages
    FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_error_intent()
    """)
  end

  defp inject_finish_failure(fixture, code, count) do
    Repo.query!("CREATE TEMP SEQUENCE persistence_failure_attempts")

    Repo.query!("""
    CREATE FUNCTION pg_temp.fail_error_finalization() RETURNS trigger AS $$
    BEGIN
      IF NEW.id = #{fixture.message.id} AND NEW.status = 'error' AND OLD.status = 'generating' THEN
        IF nextval('pg_temp.persistence_failure_attempts') <= #{count} THEN
          RAISE EXCEPTION 'Injected finalization failure' USING ERRCODE = '#{code}';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_error_finalization_failure BEFORE UPDATE ON chat_messages
    FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_error_finalization()
    """)
  end

  defp sql_attempts do
    %{rows: [[attempts]]} =
      Repo.query!("SELECT last_value FROM pg_temp.persistence_failure_attempts")

    attempts
  end

  defp fixture(adapter \\ AsyncPersistenceAdapter) do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(:create_generating_assistant, %{chat_id: chat.id}, actor: actor)
      |> Ash.create!(actor: actor)

    request = %{"model" => "test", "messages" => [], "stream" => true}
    step_id = Persistence.ensure_step_started!(message.id, request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      step_id: step_id,
      adapter_module: adapter,
      provider_type: "test",
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

  defp start_worker(fixture) do
    {:ok, lease} = Lease.acquire(fixture.message.id)

    start_supervised!(%{
      id: {Worker, fixture.message.id},
      start:
        {Worker, :start_link, [%{context: fixture.context, lease: lease, lease_owner: self()}]},
      restart: :temporary
    })
  end

  defp steps(fixture) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^fixture.message.id)
    |> Ash.read!(actor: fixture.actor)
  end
end
