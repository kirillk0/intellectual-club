defmodule IntellectualClub.Generation.StepRequestsBackfillTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.StepRequestsFixtures

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Generation.{Lease, StepRequests}
  alias IntellectualClub.Generation.StepRequests.Backfill.Job

  test "backfill requires an explicit actor and an explicit bounded message limit" do
    %{user: actor} = user_fixture()

    for opts <- [
          [],
          [actor: actor],
          [message_limit: 1],
          [actor: actor, message_limit: 0],
          [actor: actor, message_limit: 101]
        ] do
      assert {:error, _error} = StepRequests.backfill_batch(opts)
    end
  end

  test "normal reads do not backfill; default dry-run reports changes without mutating anything" do
    %{user: actor} = user_fixture()
    message = request_message!(actor)
    first = historical_request_step!(message, 1, compact_request(1), actor)
    second = historical_request_step!(message, 2, compact_request(2), actor)
    before = Enum.map([first, second], &stored_request_step!(&1.id, actor))
    _request = StepRequests.request_for_step!(second.id, actor: actor)
    assert stored_request_step!(first.id, actor).request_hash == nil

    assert {:ok, progress} = StepRequests.backfill_batch(actor: actor, message_limit: 1)
    assert progress.status == :done
    assert progress.dry_run
    assert progress.rewritten_steps == 0
    assert progress.would_rewrite_steps == 2
    assert progress.next_cursor == message.id
    assert Enum.map([first, second], &stored_request_step!(&1.id, actor)) == before
  end

  test "manual batches honor cursors and limits, preserve logical requests and are idempotent" do
    %{user: actor} = user_fixture()

    fixtures =
      for _index <- 1..3 do
        message = request_message!(actor)

        steps =
          for sequence <- 1..4,
              do: historical_request_step!(message, sequence, compact_request(sequence), actor)

        {message, steps}
      end

    [{first_message, first_steps}, {second_message, second_steps}, {third_message, third_steps}] =
      fixtures

    all_steps = first_steps ++ second_steps ++ third_steps
    before = StepRequests.requests_for_steps!(all_steps, actor: actor)

    messages_before =
      Enum.map(fixtures, fn {message, _steps} ->
        Ash.get!(ChatMessage, message.id, actor: actor)
      end)

    timestamps_before =
      Map.new(all_steps, &{&1.id, stored_request_step!(&1.id, actor).updated_at})

    assert {:ok, first_batch} =
             StepRequests.backfill_batch(
               actor: actor,
               message_limit: 2,
               after_id: first_message.id - 1,
               dry_run: false
             )

    assert first_batch.scanned_messages == 2
    assert first_batch.rewritten_messages == 2
    assert first_batch.has_more
    assert first_batch.next_cursor == second_message.id
    assert stored_request_step!(hd(third_steps).id, actor).request_hash == nil
    assert stored_request_step!(Enum.at(first_steps, 1).id, actor).request_mode == :patch

    assert {:ok, last_batch} =
             StepRequests.backfill_batch(
               actor: actor,
               message_limit: 2,
               after_id: first_batch.next_cursor,
               dry_run: false
             )

    assert last_batch.next_cursor == third_message.id
    assert last_batch.rewritten_messages == 1
    refute last_batch.has_more
    assert StepRequests.requests_for_steps!(all_steps, actor: actor) === before

    assert Enum.map(fixtures, fn {message, _steps} ->
             Ash.get!(ChatMessage, message.id, actor: actor)
           end) == messages_before

    assert Map.new(all_steps, &{&1.id, stored_request_step!(&1.id, actor).updated_at}) ==
             timestamps_before

    assert {:ok, rerun} =
             StepRequests.backfill_batch(actor: actor, message_limit: 3, dry_run: false)

    assert rerun.rewritten_steps == 0
    assert rerun.unchanged_messages == 3
    refute inspect(rerun) =~ "unchangedunchanged"
  end

  test "active, leased, oversized and unsafe histories are skipped without any rewrite" do
    %{user: actor} = user_fixture()
    active = request_message!(actor, status: :generating)
    active_step = historical_request_step!(active, 1, compact_request(1), actor)
    waiting = request_message!(actor)

    waiting_step =
      historical_request_step!(waiting, 1, compact_request(1), actor, %{status: :waiting_provider})

    large = request_message!(actor)

    large_steps =
      for sequence <- 1..3,
          do: historical_request_step!(large, sequence, compact_request(sequence), actor)

    gap = request_message!(actor)
    gap_step = historical_request_step!(gap, 2, compact_request(2), actor)
    leased = request_message!(actor)
    leased_step = historical_request_step!(leased, 1, compact_request(1), actor)
    {:ok, lease} = Lease.reserve(leased.id)

    try do
      assert {:ok, progress} =
               StepRequests.backfill_batch(
                 actor: actor,
                 message_limit: 5,
                 max_steps_per_message: 2,
                 dry_run: false
               )

      assert progress.rewritten_steps == 0
      assert progress.skipped_messages == 5

      assert Map.new(progress.skips, &{&1.message_id, &1.reason}) == %{
               active.id => :active_or_unsafe_message,
               waiting.id => :active_steps,
               large.id => :step_limit_exceeded,
               gap.id => :sequence_gap,
               leased.id => :active_generation
             }

      for step <- [active_step, waiting_step, gap_step, leased_step | large_steps] do
        assert stored_request_step!(step.id, actor).request_hash == nil

        assert StepRequests.request_for_step!(step.id, actor: actor) ==
                 compact_request(step.sequence)
      end
    after
      Lease.release(lease)
    end
  end

  test "mixed existing patch chains and historical full rows remain valid across backfill and rerun" do
    %{user: actor} = user_fixture()
    message = request_message!(actor)
    first = historical_request_step!(message, 1, compact_request(1), actor)

    second =
      encoded_request_step!(message, 2, compact_request(2), actor,
        previous_step: first,
        previous_request: compact_request(1)
      )

    third = historical_request_step!(message, 3, compact_request(3), actor)
    fourth = historical_request_step!(message, 4, compact_request(4), actor)
    steps = [first, second, third, fourth]
    before = StepRequests.requests_for_steps!(steps, actor: actor)
    patch_before = stored_request_step!(second.id, actor)

    assert {:ok, %{rewritten_messages: 1}} =
             StepRequests.backfill_batch(actor: actor, message_limit: 1, dry_run: false)

    assert stored_request_step!(second.id, actor) == patch_before
    assert StepRequests.requests_for_steps!(steps, actor: actor) === before

    assert {:ok, %{rewritten_steps: 0}} =
             StepRequests.backfill_batch(actor: actor, message_limit: 1, dry_run: false)
  end

  test "opaque reference-shaped JSON is preserved, with no materialization or provider interpretation" do
    %{user: actor} = user_fixture()
    message = request_message!(actor)

    requests =
      for index <- 1..3 do
        Map.put(compact_request(index), "opaque_reference", %{
          "type" => "unknown",
          "key" => "do-not-resolve",
          "nested" => [nil, false]
        })
      end

    steps =
      requests
      |> Enum.with_index(1)
      |> Enum.map(fn {request, sequence} ->
        historical_request_step!(message, sequence, request, actor)
      end)

    assert {:ok, %{rewritten_messages: 1}} =
             StepRequests.backfill_batch(actor: actor, message_limit: 1, dry_run: false)

    assert StepRequests.requests_for_steps!(steps, actor: actor) ==
             Map.new(Enum.zip(steps, requests), fn {step, request} -> {step.id, request} end)
  end

  test "physical re-encoding leaves request-file bindings and logical files untouched" do
    %{user: actor} = user_fixture()
    message = request_message!(actor)
    reference = Ash.UUID.generate()
    request = Map.put(compact_request(1), "opaque_reference", reference)
    first = historical_request_step!(message, 1, request, actor)
    second = historical_request_step!(message, 2, request, actor)

    {:ok, file} =
      IntellectualClub.Files.create_from_binary(
        "storage-test.bin",
        "application/octet-stream",
        reference
      )

    binding =
      IntellectualClub.Chat.ChatMessageStepRequestFile
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: second.id,
          file_id: file.id,
          reference_key: reference,
          source_file_external_id: file.external_id,
          variant_key: "opaque:test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    try do
      before =
        Ash.get!(IntellectualClub.Chat.ChatMessageStepRequestFile, binding.id, actor: actor)

      before_file = Ash.get!(IntellectualClub.Files.File, file.id, actor: actor)

      assert {:ok, %{rewritten_messages: 1}} =
               StepRequests.backfill_batch(actor: actor, message_limit: 1, dry_run: false)

      assert Ash.get!(IntellectualClub.Chat.ChatMessageStepRequestFile, binding.id, actor: actor) ==
               before

      assert Ash.get!(IntellectualClub.Files.File, file.id, actor: actor) == before_file

      assert StepRequests.requests_for_steps!([first, second], actor: actor) == %{
               first.id => request,
               second.id => request
             }
    after
      Ash.destroy!(binding, actor: actor)
      _result = IntellectualClub.Files.GarbageCollector.collect_sha256(file.sha256)
    end
  end

  test "supervised jobs expose bounded actor-scoped status and support cooperative cancellation" do
    %{user: actor} = user_fixture()
    %{user: stranger} = user_fixture()
    message = request_message!(actor)
    _step = historical_request_step!(message, 1, compact_request(1), actor)
    job = start_supervised!({Job, actor: actor, message_limit: 1, dry_run: true})
    assert {:error, :not_found} = StepRequests.backfill_status(job, actor: stranger)
    assert {:error, :not_found} = StepRequests.cancel_backfill(job, actor: stranger)
    assert {:ok, canceled_or_done} = StepRequests.cancel_backfill(job, actor: actor)
    assert canceled_or_done.status in [:canceled, :done]
    assert {:ok, same} = StepRequests.backfill_status(job, actor: actor)
    assert same == canceled_or_done
    refute inspect(same) =~ "unchangedunchanged"
  end

  test "a background batch ends at its explicit bound and returns no raw payloads" do
    %{user: actor} = user_fixture()

    for _index <- 1..2 do
      message = request_message!(actor)
      _step = historical_request_step!(message, 1, compact_request(1), actor)
    end

    job = start_supervised!({Job, actor: actor, message_limit: 1, dry_run: false})
    progress = await_job(job, actor, 10)
    assert progress.status == :done
    assert progress.scanned_messages == 1
    assert progress.has_more
    refute inspect(progress) =~ "unchangedunchanged"
  end

  defp await_job(_job, _actor, 0), do: flunk("backfill job did not finish its bounded batch")

  defp await_job(job, actor, attempts) do
    assert {:ok, progress} = StepRequests.backfill_status(job, actor: actor)

    if progress.status in [:done, :canceled, :failed],
      do: progress,
      else: await_job(job, actor, attempts - 1)
  end
end
