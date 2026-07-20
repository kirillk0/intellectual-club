defmodule IntellectualClubWeb.Bff.SerializerTest do
  @moduledoc """
  Unit tests for BFF serializer ordering guarantees.
  """

  use ExUnit.Case, async: true

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClubWeb.Bff.Serializer

  test "chat_relation_summary serializes spawn kind and the loaded last message status" do
    serialized =
      Serializer.chat_relation_summary(%Chat{
        id: 10,
        note: "Child",
        subagent: true,
        parent_relation_kind: :spawn,
        last_message: %ChatMessage{id: 20, status: :error}
      })

    assert serialized.active_generation_message_id == nil
    assert serialized.last_message_status == "error"
    assert serialized.background_task == false
    assert serialized.kind == "spawn"
  end

  test "branch_message sorts nested steps, items, and contents by sequence" do
    message =
      %ChatMessage{
        id: 11,
        role: :assistant,
        status: :done,
        steps: [
          %ChatMessageStep{
            id: 102,
            sequence: 2,
            status: :done,
            items: [
              %ChatMessageItem{
                id: 202,
                sequence: 2,
                type: :answer,
                contents: [
                  %ChatMessageContent{id: 302, sequence: 2, kind: :text, content_text: "beta"},
                  %ChatMessageContent{id: 301, sequence: 1, kind: :text, content_text: "alpha"}
                ]
              },
              %ChatMessageItem{
                id: 201,
                sequence: 1,
                type: :answer,
                contents: [
                  %ChatMessageContent{id: 303, sequence: 1, kind: :text, content_text: "first"}
                ]
              }
            ]
          },
          %ChatMessageStep{
            id: 101,
            sequence: 1,
            status: :done,
            items: [
              %ChatMessageItem{
                id: 203,
                sequence: 1,
                type: :answer,
                contents: [
                  %ChatMessageContent{id: 304, sequence: 1, kind: :text, content_text: "root"}
                ]
              }
            ]
          }
        ]
      }

    serialized = Serializer.branch_message(message)

    assert Enum.map(serialized.steps, & &1.sequence) == [1, 2]

    [step_one, step_two] = serialized.steps
    assert Enum.map(step_one.items, & &1.sequence) == [1]
    assert Enum.map(step_two.items, & &1.sequence) == [1, 2]

    [first_item, second_item] = step_two.items
    assert Enum.map(first_item.contents, & &1.sequence) == [1]
    assert Enum.map(second_item.contents, & &1.sequence) == [1, 2]
    assert Enum.map(second_item.contents, & &1.content_text) == ["alpha", "beta"]
  end

  test "step serializes time to first token and tps" do
    started_at = ~U[2026-04-16 10:00:00.000000Z]
    first_token_at = ~U[2026-04-16 10:00:00.250000Z]
    finished_at = ~U[2026-04-16 10:00:02.250000Z]

    serialized =
      Serializer.step(%ChatMessageStep{
        id: 101,
        sequence: 1,
        created_at: started_at,
        first_token_at: first_token_at,
        finished_at: finished_at,
        status: :done,
        output_tokens: 20,
        items: []
      })

    assert serialized.time_to_first_token_ms == 250
    assert_in_delta serialized.tokens_per_second, 10.0, 0.0001
  end

  test "runtime snapshot media is projected through the serializer boundary" do
    snapshot =
      RuntimeTrace.new_step()
      |> RuntimeTrace.apply_event(
        {:set_media, "attachment", :artifact, 1,
         %{
           external_id: "content-123",
           file_id: 42,
           file: %{
             id: 42,
             external_id: "file-123",
             filename: "report.pdf",
             mime_type: "application/pdf",
             size_bytes: 128,
             sha256: "sha256"
           }
         }}
      )
      |> RuntimeTrace.snapshot()

    assert %{items: [%{type: "artifact", contents: [%{kind: "media"}]}]} = snapshot

    normalized = Serializer.normalize_runtime_step_for_client(snapshot)

    assert [%{contents: [%{kind: "media", media: media}]}] = normalized.items

    assert media == %{
             external_id: "content-123",
             file_external_id: "file-123",
             filename: "report.pdf",
             mime_type: "application/pdf",
             size_bytes: 128,
             sha256: "sha256",
             is_image: false,
             file_id: 42
           }
  end

  test "display item and media snapshots keep handoff item identity" do
    step = %ChatMessageStep{id: 101, sequence: 2}
    item = %ChatMessageItem{id: 202, sequence: 3, type: :handoff_summary}

    assert Serializer.display_item_snapshot(item, step) == %{
             step_id: 101,
             step_sequence: 2,
             item_id: 202,
             item_sequence: 3,
             item_type: "handoff_summary"
           }

    content = %ChatMessageContent{
      id: 303,
      external_id: "content-303",
      sequence: 4,
      kind: :media,
      content_json: %{"media_type" => "image", "url" => "https://example.test/image.png"}
    }

    snapshot = Serializer.media_content_snapshot(content, item, step)
    assert snapshot.item_type == "handoff_summary"
    assert snapshot.item_id == item.id
    assert snapshot.step_id == step.id
  end

  test "working summary includes completed duration and active step start" do
    step_1_started_at = ~U[2026-04-16 10:00:00.000000Z]
    step_1_finished_at = ~U[2026-04-16 10:00:02.250000Z]
    step_2_started_at = ~U[2026-04-16 10:00:03.000000Z]
    step_2_finished_at = ~U[2026-04-16 10:00:04.000000Z]
    active_started_at = ~U[2026-04-16 10:00:05.000000Z]

    summary =
      Serializer.working_summary([
        %{
          id: 101,
          sequence: 1,
          created_at: DateTime.to_iso8601(step_1_started_at),
          finished_at: DateTime.to_iso8601(step_1_finished_at),
          status: "done"
        },
        %{
          id: 102,
          sequence: 2,
          created_at: DateTime.to_iso8601(step_2_started_at),
          finished_at: DateTime.to_iso8601(step_2_finished_at),
          status: "done"
        },
        %{
          id: 103,
          sequence: 3,
          created_at: DateTime.to_iso8601(active_started_at),
          finished_at: nil,
          status: "waiting_tools"
        }
      ])

    assert summary.step_count == 3
    assert summary.latest_step_id == 103
    assert summary.latest_step_sequence == 3
    assert summary.latest_step_status == "waiting_tools"
    assert summary.latest_successful_step_sequence == 3
    assert summary.completed_step_duration_ms == 3250
    assert summary.active_step_started_at == DateTime.to_iso8601(active_started_at)
  end

  test "working summary includes retry error diagnostics" do
    latest_retry_at = ~U[2026-04-16 10:00:03.000000Z]

    summary =
      Serializer.working_summary(
        [
          %{
            id: 101,
            sequence: 1,
            created_at: "2026-04-16T10:00:00Z",
            finished_at: "2026-04-16T10:00:01Z",
            status: "error"
          },
          %{
            id: 102,
            sequence: 2,
            created_at: "2026-04-16T10:00:02Z",
            finished_at: nil,
            status: "waiting_provider"
          }
        ],
        [
          %{
            step_sequence: 1,
            item_sequence: 1,
            text: "Transient provider error on attempt 1.",
            created_at: ~U[2026-04-16 10:00:01.000000Z]
          },
          %{
            step_sequence: 1,
            item_sequence: 2,
            text: "Transient provider error on attempt 2.",
            created_at: latest_retry_at
          }
        ]
      )

    assert summary.retry_error_count == 2
    assert summary.latest_retry_error_text == "Transient provider error on attempt 2."
    assert summary.latest_retry_error_at == DateTime.to_iso8601(latest_retry_at)
    assert summary.latest_retry_error_step_sequence == 1
    assert summary.latest_successful_step_sequence == nil
  end

  test "working summary treats waiting tools as successful provider completion after retry error" do
    latest_retry_at = ~U[2026-04-16 10:00:01.000000Z]

    summary =
      Serializer.working_summary(
        [
          %{
            id: 101,
            sequence: 1,
            created_at: "2026-04-16T10:00:00Z",
            finished_at: "2026-04-16T10:00:01Z",
            status: "error"
          },
          %{
            id: 102,
            sequence: 2,
            created_at: "2026-04-16T10:00:02Z",
            finished_at: nil,
            status: "waiting_tools"
          }
        ],
        [
          %{
            step_sequence: 1,
            item_sequence: 1,
            text: "Transient provider error on attempt 1.",
            created_at: latest_retry_at
          }
        ]
      )

    assert summary.retry_error_count == 1
    assert summary.latest_retry_error_step_sequence == 1
    assert summary.latest_step_sequence == 2
    assert summary.latest_step_status == "waiting_tools"
    assert summary.latest_successful_step_sequence == 2
  end

  test "usage summary keeps the latest step with token usage" do
    usage =
      Serializer.usage_summary([
        %{
          id: 101,
          sequence: 1,
          status: "done",
          input_tokens: 120,
          output_tokens: 20,
          cached_input_tokens: 12,
          reasoning_tokens: 4,
          time_to_first_token_ms: 250,
          tokens_per_second: 10.0,
          cost: 0.01
        },
        %{
          id: 102,
          sequence: 2,
          status: "waiting_provider",
          input_tokens: nil,
          output_tokens: nil,
          cost: nil
        }
      ])

    assert usage.latest_step.id == 101
    assert usage.latest_step.input_tokens == 120
    assert usage.latest_step.output_tokens == 20
    assert usage.total.input_tokens == 120
    assert usage.total.output_tokens == 20
    assert usage.total.cached_input_tokens == 12
    assert usage.total.reasoning_tokens == 4
    assert usage.total.time_to_first_token_ms == 250
    assert usage.total.tokens_per_second == 10.0
    assert usage.total.cost == 0.01
    assert usage.total_cost == 0.01
  end

  test "usage summary totals step stats across all steps" do
    usage =
      Serializer.usage_summary([
        %{
          id: 101,
          sequence: 1,
          status: "done",
          input_tokens: 120,
          output_tokens: 20,
          cached_input_tokens: 12,
          reasoning_tokens: 4,
          time_to_first_token_ms: 250,
          tokens_per_second: 10.0,
          cost: 0.01
        },
        %{
          id: 102,
          sequence: 2,
          status: "done",
          input_tokens: 80,
          output_tokens: 10,
          cached_input_tokens: 8,
          reasoning_tokens: 2,
          time_to_first_token_ms: 150,
          tokens_per_second: 5.0,
          cost: 0.02
        }
      ])

    assert usage.total.input_tokens == 200
    assert usage.total.output_tokens == 30
    assert usage.total.cached_input_tokens == 20
    assert usage.total.reasoning_tokens == 6
    assert usage.total.time_to_first_token_ms == 400
    assert_in_delta usage.total.tokens_per_second, 7.5, 0.0001
    assert usage.total.cost == 0.03
    assert usage.total_cost == 0.03
  end

  test "usage summary falls back to latest step when no token usage exists" do
    usage =
      Serializer.usage_summary([
        %{id: 101, sequence: 1, status: "done", input_tokens: nil, output_tokens: nil},
        %{id: 102, sequence: 2, status: "done", input_tokens: nil, output_tokens: nil}
      ])

    assert usage.latest_step.id == 102
  end
end
