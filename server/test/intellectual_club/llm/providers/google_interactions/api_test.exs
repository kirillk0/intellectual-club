defmodule IntellectualClub.Llm.Providers.GoogleInteractions.ApiTest do
  use ExUnit.Case, async: true

  import IntellectualClub.ProviderStreamHelpers
  import IntellectualClub.TestHttpServer

  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.GoogleInteractions.Api

  test "streams interaction events into trace and hydrated raw response steps" do
    scripts = %{
      "/interactions" => [
        {200,
         google_sse_chunks([
           %{
             "event_type" => "interaction.created",
             "interaction" => %{
               "id" => "",
               "status" => "in_progress",
               "object" => "interaction",
               "model" => "gemini-2.5-flash-lite"
             }
           },
           %{
             "event_type" => "step.start",
             "index" => 0,
             "step" => %{"type" => "thought"}
           },
           %{
             "event_type" => "step.delta",
             "index" => 0,
             "delta" => %{
               "type" => "thought_summary",
               "content" => %{"type" => "text", "text" => "Need answer."}
             }
           },
           %{
             "event_type" => "step.stop",
             "index" => 0
           },
           %{
             "event_type" => "step.start",
             "index" => 1,
             "step" => %{"type" => "model_output"}
           },
           %{
             "event_type" => "step.delta",
             "index" => 1,
             "delta" => %{"type" => "text", "text" => "pong"}
           },
           %{
             "event_type" => "step.stop",
             "index" => 1
           },
           %{
             "event_type" => "interaction.completed",
             "interaction" => %{
               "status" => "completed",
               "usage" => %{
                 "total_input_tokens" => 5,
                 "total_output_tokens" => 1,
                 "total_cached_tokens" => 0,
                 "total_thought_tokens" => 2,
                 "total_tokens" => 8
               },
               "object" => "interaction",
               "model" => "gemini-2.5-flash-lite"
             }
           }
         ])}
      ]
    }

    {base_url, agent} =
      start_scripted_server!(scripts, record: :request, error_content_type: "application/json")

    events =
      run_and_capture_events!(Api, %{
        base_url: base_url,
        api_key: "test-key",
        request_payload: %{
          "model" => "gemini-2.5-flash-lite",
          "input" => "Return exactly: pong",
          "stream" => true,
          "store" => false
        },
        timeout_ms: provider_deadline_ms(),
        connect_timeout_ms: provider_deadline_ms()
      })

    [request] = scripted_requests(agent, "/interactions")
    assert {"x-goog-api-key", "test-key"} in request.headers
    assert request.payload["store"] == false

    meta =
      Enum.find_value(events, fn
        {:response_complete, meta} -> meta
        _other -> nil
      end)

    assert meta.usage.input_tokens == 5
    assert meta.usage.output_tokens == 3
    assert meta.usage.reasoning_tokens == 2

    assert meta.raw_response["steps"] == [
             %{
               "type" => "thought",
               "summary" => [%{"type" => "text", "text" => "Need answer."}]
             },
             %{
               "type" => "model_output",
               "content" => [%{"type" => "text", "text" => "pong"}]
             }
           ]

    runtime_step = trace_step(events)

    assert RuntimeTrace.text_for_item_type(runtime_step, :reasoning) == "Need answer."
    assert RuntimeTrace.text_for_item_type(runtime_step, :answer) == "pong"
    assert runtime_step.output_tokens == 3
    assert runtime_step.reasoning_tokens == 2
  end
end
