defmodule IntellectualClub.Generation.LegacyRequestImagesBackfillTest do
  use IntellectualClub.DataCase, async: false

  import ExUnit.CaptureIO

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep}
  alias IntellectualClub.Generation.LegacyRequestImages.Backfill
  alias IntellectualClub.Repo

  @advisory_lock_key 4_962_434_762_617

  test "reports a partial scan with a safe resume cursor" do
    fixture = step_fixture!()

    assert {:ok, stats} =
             Backfill.run(
               after_id: fixture.first_step.id - 1,
               through_id: fixture.second_step.id,
               max_steps: 1
             )

    assert stats.scanned == 1
    assert stats.scanned_through_id == fixture.first_step.id
    assert stats.resume_after_id == fixture.first_step.id
    assert stats.scan_complete == false
    assert stats.complete == false
    assert stats.unresolved_count == 0
    assert stats.unresolved_step_ids == []
  end

  test "reports active and failed rows explicitly and resumes before the first one" do
    fixture = step_fixture!()

    active_step =
      fixture.second_step
      |> Ash.Changeset.for_update(:update, %{status: :waiting_provider}, authorize?: false)
      |> Ash.update!(authorize?: false)

    assert {:ok, active_stats} =
             Backfill.run(
               after_id: fixture.first_step.id,
               through_id: active_step.id
             )

    assert active_stats.scan_complete
    refute active_stats.complete
    assert active_stats.active_skipped == 1
    assert active_stats.unresolved_step_ids == [active_step.id]
    assert active_stats.resume_after_id == active_step.id - 1

    invalid_request = %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "[Attached file file_id=#{Ash.UUID.generate()}]"
            },
            %{
              "type" => "input_image",
              "image_url" => "data:image/png;base64,not-valid-base64!"
            }
          ]
        }
      ]
    }

    failed_step =
      active_step
      |> Ash.Changeset.for_update(
        :update,
        %{status: :done, raw_request: invalid_request},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

    assert {:ok, failed_stats} =
             Backfill.run(
               after_id: fixture.first_step.id,
               through_id: failed_step.id
             )

    assert failed_stats.scan_complete
    refute failed_stats.complete
    assert failed_stats.failed == 1
    assert failed_stats.unresolved_step_ids == [failed_step.id]
    assert failed_stats.resume_after_id == failed_step.id - 1
  end

  test "mix task fails on unresolved rows unless allow-errors is explicit" do
    fixture = step_fixture!()

    active_step =
      fixture.second_step
      |> Ash.Changeset.for_update(:update, %{status: :waiting_provider}, authorize?: false)
      |> Ash.update!(authorize?: false)

    args = [
      "--dry-run",
      "--after-id",
      Integer.to_string(fixture.first_step.id),
      "--through-id",
      Integer.to_string(active_step.id)
    ]

    assert_raise Mix.Error, ~r/Backfill has 1 unresolved step/, fn ->
      capture_io(fn ->
        Mix.Tasks.IntellectualClub.BackfillRawRequestImages.run(args)
      end)
    end

    output =
      capture_io(fn ->
        assert :ok ==
                 Mix.Tasks.IntellectualClub.BackfillRawRequestImages.run([
                   "--allow-errors" | args
                 ])
      end)

    assert output =~ "BACKFILL_SUMMARY"
    assert output =~ ~s("complete":false)
    assert output =~ ~s("resume_after_id":#{active_step.id - 1})
  end

  test "mix task treats an intentional max-steps boundary as resumable success" do
    fixture = step_fixture!()

    output =
      capture_io(fn ->
        assert :ok ==
                 Mix.Tasks.IntellectualClub.BackfillRawRequestImages.run([
                   "--dry-run",
                   "--after-id",
                   Integer.to_string(fixture.first_step.id - 1),
                   "--through-id",
                   Integer.to_string(fixture.second_step.id),
                   "--max-steps",
                   "1"
                 ])
      end)

    assert output =~ "BACKFILL_INCOMPLETE"
    assert output =~ "--after-id #{fixture.first_step.id}"
    assert output =~ ~s("scan_complete":false)
  end

  test "a completed run does not leak its advisory lock" do
    fixture = step_fixture!()

    assert {:ok, %{complete: true}} =
             Backfill.run(
               after_id: fixture.first_step.id - 1,
               through_id: fixture.second_step.id
             )

    assert {:ok, %{rows: [[true]]}} =
             Repo.query("SELECT pg_try_advisory_lock($1)", [@advisory_lock_key])

    assert {:ok, %{rows: [[true]]}} =
             Repo.query("SELECT pg_advisory_unlock($1)", [@advisory_lock_key])

    assert {:ok, %{rows: [[false]]}} =
             Repo.query("SELECT pg_advisory_unlock($1)", [@advisory_lock_key])
  end

  defp step_fixture! do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: chat.id,
          role: :assistant,
          status: :done,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    first_step = create_step!(message.id, 1, actor)
    second_step = create_step!(message.id, 2, actor)

    %{first_step: first_step, second_step: second_step}
  end

  defp create_step!(message_id, sequence, actor) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_id: message_id,
        sequence: sequence,
        status: :done,
        raw_request: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
