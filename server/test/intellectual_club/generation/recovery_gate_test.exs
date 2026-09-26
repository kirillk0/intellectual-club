defmodule IntellectualClub.Generation.RecoveryGateTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageItem, ChatMessageStep, Subagent}
  alias IntellectualClub.Generation.{Lease, RecoveryGate}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  require Ash.Query

  @now ~U[2030-01-01 00:00:00.000000Z]

  test "ordinary fresh starts neither initialize nor write a recovery guard" do
    fixture = fixture()
    before = Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor)
    assert {:ok, :fresh} = admit(fixture, mode: :start)
    after_start = Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor)
    assert before.updated_at == after_start.updated_at
    assert recovery(fixture) == nil

    assert Ash.Resource.Info.attribute(ChatMessage, :generation_recovery).public? == false
    assert Ash.Resource.Info.action(ChatMessage, :set_generation_recovery).accept == []
    assert {:error, _} = RecoveryGate.admit(fixture.message.id, nil, nil)
    assert recovery(fixture) == nil
  end

  test "ordinary action params cannot mutate or clear the private recovery guard" do
    fixture = fixture()
    assert {:ok, :recorded} = record(fixture, terminal_status: :error)
    guard = recovery(fixture)
    message = Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor)

    assert {:error, _reason} =
             message
             |> Ash.Changeset.for_update(:set_generation_recovery, %{recovery: nil},
               actor: fixture.actor
             )
             |> Ash.update(actor: fixture.actor)

    assert recovery(fixture) == guard
  end

  test "unchanged progress exhausts exactly three admissions and finishes minimally" do
    fixture = fixture()
    assert {:ok, :admitted} = admit(fixture)
    assert recovery(fixture)["attempts"] == 1
    assert {:ok, :admitted} = admit(fixture, now: DateTime.add(@now, 250, :millisecond))
    assert recovery(fixture)["attempts"] == 2
    assert {:ok, :admitted} = admit(fixture, now: DateTime.add(@now, 1_250, :millisecond))
    assert recovery(fixture)["attempts"] == 3

    assert {:ok, {:finish, :error}} =
             admit(fixture, now: DateTime.add(@now, 6_250, :millisecond))

    assert recovery(fixture)["terminal_status"] == "error"
    assert {:ok, :error} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)
    message = Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor)
    assert message.status == :error
    assert message.error_detail =~ "without durable progress"
    assert message.finished_at
    step = Ash.get!(ChatMessageStep, fixture.step.id, actor: fixture.actor)
    assert step.status == :error
    assert step.finished_at
    assert {:ok, :error} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)
  end

  test "cooldown cannot be bypassed by registration, admission modes, or Supervisor entrypoints" do
    fixture = fixture()
    assert {:ok, :admitted} = admit(fixture)
    guard = recovery(fixture)
    retry_at = DateTime.add(@now, 250, :millisecond)

    for _ <- 1..3 do
      assert {:ok, :recorded} = record(fixture)
      assert {:error, {:recovery_deferred, ^retry_at}} = admit(fixture)
      assert {:error, {:recovery_deferred, ^retry_at}} = admit(fixture, mode: :start)
    end

    assert recovery(fixture)["attempts"] == guard["attempts"]
    assert recovery(fixture)["next_retry_at"] == guard["next_retry_at"]

    assert {:error, {:recovery_deferred, ^retry_at}} =
             GenerationSupervisor.resume_orphaned_message(fixture.message.id,
               actor: fixture.actor
             )

    assert {:error, {:recovery_deferred, ^retry_at}} =
             GenerationSupervisor.start_prepared_context(context(fixture))

    assert {:error, {:recovery_deferred, ^retry_at}} =
             GenerationSupervisor.start_prepared_generation(
               fixture.chat.id,
               fixture.message.id,
               fixture.step.id,
               %{},
               actor: fixture.actor
             )

    assert :ok = Subagent.resume_generation_if_needed(fixture.message.id, fixture.actor)
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :generating
    assert recovery(fixture)["attempts"] == 1
    assert GenerationSupervisor.generation_worker_pid(fixture.message.id) == nil
  end

  test "child provider-start deferral keeps the committed reference without cancellation" do
    reference = %{chat_id: 11, generation_message_id: 22}
    caller = self()
    deferred = {:error, {:recovery_deferred, @now}}

    assert {:ok, ^reference} =
             Subagent.start_invocation(
               %IntellectualClub.Tools.ExecutionContext{},
               reference,
               [
                 on_reference: fn _ ->
                   send(caller, :reference_committed)
                   :ok
                 end
               ],
               fn _ -> flunk("A deferred child must not be canceled") end,
               fn -> deferred end
             )

    assert_received :reference_committed

    # The same-shaped reference/authority failure is NOT a successful start.
    assert {:error, _} =
             Subagent.start_invocation(
               %IntellectualClub.Tools.ExecutionContext{},
               reference,
               [on_reference: fn _ -> deferred end],
               fn _ -> send(caller, :invalid_reference_canceled) end,
               fn -> flunk("Provider start requires committed authority") end
             )

    assert_received :invalid_reference_canceled
  end

  test "waiting_provider replacement ID and renewed lease do not reset the budget" do
    fixture = fixture()
    assert {:ok, :admitted} = admit(fixture)
    guard = recovery(fixture)
    Ash.destroy!(fixture.step, actor: fixture.actor)
    replacement = step!(fixture, 1)
    assert replacement.id != fixture.step.id
    assert {:ok, lease} = Lease.acquire(fixture.message.id)

    try do
      assert {:ok, :admitted} =
               RecoveryGate.admit(fixture.message.id, lease, fixture.actor,
                 now: DateTime.add(@now, 250, :millisecond),
                 jitter_ratio: 0
               )

      assert recovery(fixture)["progress"] == guard["progress"]
      assert recovery(fixture)["attempts"] == 2
    after
      Lease.release(lease)
    end
  end

  test "provider final commit and new receipt sequences reset the budget" do
    fixture = fixture()
    assert {:ok, :admitted} = admit(fixture)
    initial = recovery(fixture)

    step =
      update_step!(fixture.step, %{response_final: true, status: :waiting_tools}, fixture.actor)

    assert {:ok, :admitted} = admit(fixture)
    assert recovery(fixture)["attempts"] == 1
    refute recovery(fixture)["progress"] == initial["progress"]
    after_provider = recovery(fixture)

    call = item!(step.id, 1, :tool_call, fixture.actor)
    _receipt = item!(step.id, 2, :tool_result, fixture.actor, call.id)
    assert {:ok, :admitted} = admit(fixture)
    assert recovery(fixture)["attempts"] == 1
    refute recovery(fixture)["progress"] == after_provider["progress"]
    after_receipt = recovery(fixture)

    update_step!(step, %{finished_at: DateTime.utc_now()}, fixture.actor)
    assert {:error, {:recovery_deferred, _}} = admit(fixture)
    assert recovery(fixture) == after_receipt
  end

  test "successor requests keep provider auto-retry unbounded by the recovery budget" do
    fixture = fixture()

    Enum.reduce(1..12, fixture.step, fn sequence, previous ->
      step =
        if sequence == 1 do
          previous
        else
          update_step!(previous, %{status: :error}, fixture.actor)
          step!(fixture, sequence)
        end

      assert {:ok, :admitted} = admit(fixture)
      assert recovery(fixture)["attempts"] == 1
      assert recovery(fixture)["terminal_status"] == nil
      step
    end)
  end

  test "terminal intent is sticky across progress and failed fenced finalization" do
    fixture = fixture()
    assert {:ok, lease} = Lease.acquire(fixture.message.id)

    assert {:ok, :recorded} =
             RecoveryGate.record_failure(fixture.message.id, lease, fixture.actor,
               operation: :provider_completed,
               error: "Permanent sanitized failure",
               terminal_status: :error
             )

    assert :ok = Lease.release(lease)
    assert {:error, :lease_lost} = RecoveryGate.finish(fixture.message.id, lease, fixture.actor)
    assert recovery(fixture)["terminal_status"] == "error"

    assert {:ok, :recorded} =
             record(fixture, terminal_status: :canceled, error: "Different failure")

    update_step!(fixture.step, %{response_final: true, status: :done}, fixture.actor)
    _successor = step!(fixture, 2)
    assert {:ok, {:finish, :error}} = admit(fixture)
    assert {:ok, {:finish, :error}} = admit(fixture, mode: :start)
    assert recovery(fixture)["error"] == "Permanent sanitized failure"

    assert {:ok, %{status: :error, recovery_finished?: true}} =
             GenerationSupervisor.start_prepared_context(context(fixture))

    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :error
    assert Ash.get!(ChatMessageStep, fixture.step.id, actor: fixture.actor).status == :done
    assert GenerationSupervisor.generation_worker_pid(fixture.message.id) == nil
  end

  test "terminal status survives later registrations, finish, and attempted downgrade" do
    for status <- [:done, :canceled, :error] do
      fixture = fixture()
      assert {:ok, :recorded} = record(fixture, terminal_status: :error)

      fixture.message
      |> Ash.Changeset.for_update(:set_generation_state, %{status: status}, actor: fixture.actor)
      |> Ash.update!(actor: fixture.actor)

      assert {:ok, {:finished, ^status}} = record(fixture, terminal_status: :canceled)
      assert {:ok, {:finished, ^status}} = admit(fixture)
      assert {:ok, ^status} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)
      assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == status
    end
  end

  test "owner authorization, role, and stale message fence are enforced" do
    fixture = fixture()
    %{user: stranger} = user_fixture()
    assert {:error, _} = RecoveryGate.admit(fixture.message.id, nil, stranger)
    assert {:error, _} = RecoveryGate.record_failure(fixture.message.id, nil, stranger, failure())
    assert {:error, _} = RecoveryGate.finish(fixture.message.id, nil, stranger)
    assert recovery(fixture) == nil

    assert {:ok, lease} = Lease.acquire(fixture.message.id)

    try do
      assert {:error, :lease_lost} =
               RecoveryGate.record_failure(
                 fixture.message.id,
                 %{lease | fence_token: Ecto.UUID.generate()},
                 fixture.actor,
                 failure()
               )

      assert {:error, :invalid_generation_lease} =
               RecoveryGate.admit(fixture.message.id + 1, lease, fixture.actor)

      assert recovery(fixture) == nil
    after
      Lease.release(lease)
    end

    input =
      ChatMessage
      |> Ash.Changeset.for_create(:add_user_message, %{chat_id: fixture.chat.id},
        actor: fixture.actor
      )
      |> Ash.create!(actor: fixture.actor)

    assert {:error, :invalid_role} = RecoveryGate.admit(input.id, nil, fixture.actor)

    assert {:error, :invalid_role} =
             RecoveryGate.record_failure(input.id, nil, fixture.actor, failure())
  end

  test "registration uses bounded JSON strings and no request or response reads" do
    fixture = fixture()
    handler = {__MODULE__, make_ref()}
    caller = self()

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == caller, do: send(caller, {:gate_query, metadata.query})
        end,
        nil
      )

    try do
      assert {:ok, :recorded} = record(fixture, error: String.duplicate("x", 2_000))
      assert {:ok, :admitted} = admit(fixture)
      assert recovery(fixture)["operation"] == "provider_completed"
      assert String.length(recovery(fixture)["error"]) == 1_000
      assert {:ok, :recorded} = record(fixture, terminal_status: :canceled)
      assert {:ok, :canceled} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)

      for query <- queries([]) do
        refute query =~ "raw_request", query
        refute query =~ "raw_response", query
        refute query =~ "request_patch", query
      end
    after
      :telemetry.detach(handler)
    end
  end

  test "policy rejects invalid budgets and timestamps instead of silently disabling the gate" do
    fixture = fixture()

    for opts <- [
          [max_attempts: 0],
          [max_attempts: :infinity],
          [retry_delays_ms: []],
          [retry_delays_ms: [0]],
          [retry_delays_ms: [60_001]],
          [jitter_ratio: -0.1],
          [now: 0],
          [mode: :manual]
        ] do
      assert {:error, :invalid_recovery_policy} = admit(fixture, opts)
    end

    assert recovery(fixture) == nil
  end

  test "admission precedes corrupt prepare and remains bounded across later starts" do
    fixture = fixture()
    corrupt_request!(fixture)

    assert {:error, _reason} =
             GenerationSupervisor.resume_orphaned_message(fixture.message.id,
               actor: fixture.actor
             )

    assert recovery(fixture)["attempts"] == 1
    assert recovery(fixture)["operation"] == "recovery_start"

    # Advance only the gate's internal clock, never sleep or alter global config.
    assert {:ok, :admitted} = admit(fixture)
    assert {:ok, :admitted} = admit(fixture, now: DateTime.add(@now, 1_000, :millisecond))
    assert {:ok, {:finish, :error}} = admit(fixture, now: DateTime.add(@now, 6_000, :millisecond))

    assert {:ok, %{status: :error, recovery_finished?: true}} =
             GenerationSupervisor.resume_orphaned_message(fixture.message.id,
               actor: fixture.actor
             )

    assert GenerationSupervisor.generation_worker_pid(fixture.message.id) == nil
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :error
  end

  test "terminal prepared generation never decodes a corrupt request or starts external work" do
    fixture = fixture()
    corrupt_request!(fixture)
    assert {:ok, :recorded} = record(fixture, terminal_status: :canceled)

    assert {:ok, %{status: :canceled, recovery_finished?: true}} =
             GenerationSupervisor.start_prepared_generation(
               fixture.chat.id,
               fixture.message.id,
               fixture.step.id,
               %{},
               actor: fixture.actor
             )

    assert GenerationSupervisor.generation_worker_pid(fixture.message.id) == nil
    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :canceled
  end

  test "an unavailable repository cannot fabricate successful terminal finalization" do
    fixture = fixture()
    assert {:ok, :recorded} = record(fixture, terminal_status: :error)
    previous_repo = Repo.get_dynamic_repo()

    try do
      # A per-process unavailable repository, without stopping a shared Repo/PG
      # or installing any production fault-injection hook.
      Repo.put_dynamic_repo(:unavailable_recovery_gate_test_repo)
      assert {:error, _reason} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)
    after
      Repo.put_dynamic_repo(previous_repo)
    end

    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :generating
    assert recovery(fixture)["terminal_status"] == "error"

    assert {:ok, %{status: :error, recovery_finished?: true}} =
             GenerationSupervisor.resume_orphaned_message(fixture.message.id,
               actor: fixture.actor
             )

    assert GenerationSupervisor.generation_worker_pid(fixture.message.id) == nil
  end

  test "a malformed private guard fails closed rather than reopening the budget" do
    fixture = fixture()

    fixture.message
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:recovery, %{"version" => 1, "attempts" => 2})
    |> Ash.Changeset.for_update(:set_generation_recovery, %{}, actor: fixture.actor)
    |> Ash.update!(actor: fixture.actor)

    assert {:ok, {:finish, :error}} = admit(fixture)
    assert recovery(fixture)["terminal_status"] == "error"
    assert {:ok, :error} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)
  end

  test "terminal intent is independent of invalid progress and cooldown metadata" do
    fixture = fixture()

    fixture.message
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:recovery, %{
      "terminal_status" => "canceled",
      "attempts" => "invalid",
      "next_retry_at" => "invalid",
      "error" => "Cancellation must stay terminal"
    })
    |> Ash.Changeset.for_update(:set_generation_recovery, %{}, actor: fixture.actor)
    |> Ash.update!(actor: fixture.actor)

    assert {:ok, :recorded} = record(fixture, terminal_status: :error)
    assert {:ok, {:finish, :canceled}} = admit(fixture)
    assert {:ok, :canceled} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)
    assert recovery(fixture)["error"] == "Cancellation must stay terminal"
  end

  test "a rolled back minimal finish keeps terminal intent for the next startup" do
    fixture = fixture()
    assert {:ok, :recorded} = record(fixture, terminal_status: :error)

    assert {:error, _rollback_error} =
             Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
               assert {:ok, :error} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)
               Ash.DataLayer.rollback(ChatMessage, :rollback_finish)
             end)

    assert Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor).status == :generating
    assert recovery(fixture)["terminal_status"] == "error"

    assert {:ok, %{status: :error, recovery_finished?: true}} =
             GenerationSupervisor.resume_orphaned_message(fixture.message.id,
               actor: fixture.actor
             )
  end

  test "manual retry reset rolls back with replacement and clears only on explicit retry" do
    fixture = fixture()
    assert {:ok, :recorded} = record(fixture, terminal_status: :error)
    assert {:ok, :error} = RecoveryGate.finish(fixture.message.id, nil, fixture.actor)
    guard = recovery(fixture)

    assert {:error, _rollback_error} =
             Ash.transaction([Chat, ChatMessage], fn ->
               assert :ok = RecoveryGate.reset!(fixture.message.id, fixture.actor)
               Ash.DataLayer.rollback(ChatMessage, :rollback_reset)
             end)

    assert recovery(fixture) == guard

    assert {:ok, _context} =
             GenerationSupervisor.retry_last_step(fixture.message.id, actor: fixture.actor)

    assert recovery(fixture) == nil
    _ = GenerationSupervisor.cancel_generation(fixture.message.id)
  end

  defp fixture do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(:create_generating_assistant, %{chat_id: chat.id}, actor: actor)
      |> Ash.create!(actor: actor)

    fixture = %{actor: actor, chat: chat, message: message}
    Map.put(fixture, :step, step!(fixture, 1))
  end

  defp step!(fixture, sequence) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_id: fixture.message.id,
        sequence: sequence,
        status: :waiting_provider,
        raw_request: %{"model" => "demo-model", "messages" => [], "stream" => true}
      },
      actor: fixture.actor
    )
    |> Ash.create!(actor: fixture.actor)
  end

  defp update_step!(step, attrs, actor) do
    step
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp item!(step_id, sequence, type, actor, call_id \\ nil) do
    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_step_id: step_id,
        sequence: sequence,
        type: type,
        tool_call_item_id: call_id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp context(fixture) do
    %{message_id: fixture.message.id, chat_id: fixture.chat.id, owner_id: fixture.actor.id}
  end

  defp admit(fixture, opts \\ []) do
    RecoveryGate.admit(
      fixture.message.id,
      nil,
      fixture.actor,
      Keyword.merge([now: @now, jitter_ratio: 0], opts)
    )
  end

  defp failure(opts \\ []) do
    Keyword.merge([operation: :provider_completed, error: "Sanitized failure"], opts)
  end

  defp record(fixture, opts \\ []) do
    RecoveryGate.record_failure(fixture.message.id, nil, fixture.actor, failure(opts))
  end

  defp recovery(fixture) do
    ChatMessage
    |> Ash.Query.filter(id == ^fixture.message.id)
    |> Ash.Query.select([:generation_recovery])
    |> Ash.read_one!(actor: fixture.actor)
    |> Map.fetch!(:generation_recovery)
  end

  defp corrupt_request!(fixture) do
    # Deliberate test-only corruption bypasses immutable request validation.
    Repo.update_all(from(s in ChatMessageStep, where: s.id == ^fixture.step.id),
      set: [request_hash: String.duplicate("0", 64)]
    )
  end

  defp queries(acc) do
    receive do
      {:gate_query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
