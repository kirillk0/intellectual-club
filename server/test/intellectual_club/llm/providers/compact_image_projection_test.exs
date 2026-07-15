defmodule IntellectualClub.Llm.Providers.CompactImageProjectionTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Llm.Providers.AnthropicMessages.Payload, as: AnthropicPayload
  alias IntellectualClub.Llm.Providers.Common.RequestHydration
  alias IntellectualClub.Llm.Providers.GoogleInteractions.Payload, as: GooglePayload
  alias IntellectualClub.Llm.Providers.ResponsesWss.Session

  @marker %{
    "$intellectual_club_file" => %{
      "version" => 1,
      "reference_key" => "11111111-1111-4111-8111-111111111111",
      "source_file_external_id" => "22222222-2222-4222-8222-222222222222",
      "rendition" => %{
        "kind" => "fit",
        "max_edge_px" => 2_000,
        "format" => "preserve"
      },
      "encoding" => "data_url",
      "mime_type" => "image/png"
    }
  }

  test "Anthropic projection keeps compact image markers in source.data" do
    cache_control = %{"type" => "ephemeral"}
    base64_marker = put_in(@marker, ["$intellectual_club_file", "encoding"], "base64")

    {_system, messages} =
      AnthropicPayload.from_chat_messages([
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "image_url",
              "image_url" => %{"url" => @marker},
              "cache_control" => cache_control
            }
          ]
        }
      ])

    assert messages == [
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => "image/png",
                     "data" => base64_marker
                   },
                   "cache_control" => cache_control
                 }
               ]
             }
           ]
  end

  test "Google projection keeps compact image markers in image.data" do
    source_file_external_id =
      get_in(@marker, ["$intellectual_club_file", "source_file_external_id"])

    content = %{
      kind: :media,
      sequence: 1,
      external_id: "33333333-3333-4333-8333-333333333333",
      file_id: 42,
      file: %StoredFile{
        id: 42,
        external_id: source_file_external_id,
        filename: "image.png",
        mime_type: "image/png",
        size_bytes: 3,
        sha256: String.duplicate("a", 64)
      }
    }

    blocks =
      GooglePayload.tool_result_content("", [content],
        supports_image_input: true,
        provider_type: "google_interactions"
      )

    assert [%{"type" => "text"}, %{"type" => "image", "data" => marker}] = blocks
    assert get_in(marker, ["$intellectual_club_file", "encoding"]) == "base64"

    assert get_in(marker, ["$intellectual_club_file", "source_file_external_id"]) ==
             source_file_external_id
  end

  test "Responses WSS computes continuation prefixes before marker hydration" do
    initial_input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_image", "image_url" => @marker}]
      }
    ]

    output = [%{"id" => "msg_1", "type" => "message", "role" => "assistant", "content" => []}]
    delta = [%{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}]

    state = %{
      context: %{},
      connection: nil,
      last_request: %{"model" => "gpt-test", "input" => initial_input},
      last_response: %{"id" => "resp_1", "output" => output}
    }

    current = %{"model" => "gpt-test", "input" => initial_input ++ output ++ delta}

    assert {:ok, logical_transport_request} = Session.wire_payload(current, state)
    assert logical_transport_request["previous_response_id"] == "resp_1"
    assert logical_transport_request["input"] == delta
  end

  test "transport hydration reports a controlled error for a compact marker without a step" do
    logical_request = %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => @marker}]
        }
      ]
    }

    assert {:error, error} = RequestHydration.hydrate(logical_request, nil, :responses)
    assert error.error_kind == "request_hydration"
    assert error.retryable == false
    assert error.raw_request == logical_request
    assert error.raw_response == nil
  end

  test "transport hydration leaves legacy payloads untouched without a step" do
    legacy_request = %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{"type" => "input_image", "image_url" => "data:image/png;base64,cG5n"}
          ]
        }
      ]
    }

    assert {:ok, ^legacy_request} =
             RequestHydration.hydrate(legacy_request, nil, :responses)
  end
end
