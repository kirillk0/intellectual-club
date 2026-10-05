defmodule IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ChatCompletionTest do
  use ExUnit.Case, async: true

  import IntellectualClub.ProviderStreamHelpers
  import IntellectualClub.TestHttpServer

  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.Common.ChatCompletions
  alias IntellectualClub.Llm.Providers.Common.ChatHistory
  alias IntellectualClub.Llm.Providers.Common.RequestBuilder
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion.Trace

  @request_payload %{
    "model" => "deepseek/deepseek-v4-pro",
    "messages" => [%{"role" => "user", "content" => "Hello"}]
  }

  describe "request headers" do
    test "sends OpenRouter app attribution headers" do
      scripts = %{
        "/chat/completions" => [
          {200, sse_chunks([%{"choices" => [%{"delta" => %{"content" => "Hi"}}]}])}
        ]
      }

      {base_url, agent} =
        start_scripted_server!(scripts, record: :request, error_content_type: "application/json")

      :ok =
        ChatCompletion.stream_generate(
          %{
            base_url: base_url,
            api_key: "test-key",
            request_payload: @request_payload,
            timeout_ms: provider_deadline_ms(),
            connect_timeout_ms: provider_deadline_ms()
          },
          fn _event -> :ok end
        )

      [request] = scripted_requests(agent, "/chat/completions")

      assert {"http-referer", "https://github.com/kirillk0/intellectual-club"} in request.headers
      assert {"x-openrouter-title", "Intellectual Club"} in request.headers
    end

    test "shared client applies provider-specific retry statuses without OpenRouter headers" do
      scripts = %{
        "/chat/completions" => [
          {504,
           [
             Jason.encode!(%{
               "message" => "Service temporarily overloaded",
               "type" => "Overloaded",
               "code" => 504
             })
           ]}
        ]
      }

      {base_url, agent} =
        start_scripted_server!(scripts, record: :request, error_content_type: "application/json")

      parent = self()

      :ok =
        ChatCompletions.stream_generate(
          %{
            provider: :nvidia_build_chat_completion,
            image_mapper: &NvidiaBuildChatCompletion.map_request_images/3,
            base_url: base_url,
            api_key: "test-key",
            request_payload: @request_payload,
            retryable_http_status_codes: [429, 504],
            timeout_ms: provider_deadline_ms(),
            connect_timeout_ms: provider_deadline_ms()
          },
          fn event -> send(parent, {:provider_event, event}) end
        )

      assert_receive {:provider_event, {:response_error, error}}, 2_000
      assert error.provider == :nvidia_build_chat_completion
      assert error.status_code == 504, inspect(error)
      assert error.retryable == true
      assert error.error_text == "Service temporarily overloaded"

      [request] = scripted_requests(agent, "/chat/completions")
      refute Enum.any?(request.headers, fn {name, _value} -> name == "http-referer" end)
      refute Enum.any?(request.headers, fn {name, _value} -> name == "x-openrouter-title" end)
    end
  end

  describe "Trace.stream_generate/2" do
    test "emits canonical tool call trace from streamed chat completion deltas" do
      scripts = %{
        "/chat/completions" => [
          {200,
           sse_chunks([
             %{
               "id" => "gen_1",
               "object" => "chat.completion.chunk",
               "created" => 1_777_000_001,
               "model" => "openai/gpt-5-mini",
               "provider" => "OpenRouter",
               "choices" => [
                 %{
                   "index" => 0,
                   "delta" => %{
                     "role" => "assistant",
                     "content" => "",
                     "reasoning" => "Searching"
                   },
                   "finish_reason" => nil
                 }
               ]
             },
             %{
               "id" => "gen_1",
               "object" => "chat.completion.chunk",
               "created" => 1_777_000_001,
               "model" => "openai/gpt-5-mini",
               "provider" => "OpenRouter",
               "choices" => [
                 %{
                   "index" => 0,
                   "delta" => %{
                     "role" => "assistant",
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "index" => 0,
                         "id" => "call_1",
                         "type" => "function",
                         "function" => %{
                           "name" => "web__search_web",
                           "arguments" => ""
                         }
                       }
                     ]
                   },
                   "finish_reason" => nil
                 }
               ]
             },
             %{
               "id" => "gen_1",
               "object" => "chat.completion.chunk",
               "created" => 1_777_000_001,
               "model" => "openai/gpt-5-mini",
               "provider" => "OpenRouter",
               "choices" => [
                 %{
                   "index" => 0,
                   "delta" => %{
                     "role" => "assistant",
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "index" => 0,
                         "function" => %{
                           "arguments" => ~s({"query":"Open)
                         }
                       }
                     ]
                   },
                   "finish_reason" => nil
                 }
               ]
             },
             %{
               "id" => "gen_1",
               "object" => "chat.completion.chunk",
               "created" => 1_777_000_001,
               "model" => "openai/gpt-5-mini",
               "provider" => "OpenRouter",
               "choices" => [
                 %{
                   "index" => 0,
                   "delta" => %{
                     "role" => "assistant",
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "index" => 0,
                         "function" => %{
                           "arguments" => ~s(AI"})
                         }
                       }
                     ]
                   },
                   "finish_reason" => nil
                 }
               ]
             },
             %{
               "id" => "gen_1",
               "object" => "chat.completion.chunk",
               "created" => 1_777_000_001,
               "model" => "openai/gpt-5-mini",
               "provider" => "OpenRouter",
               "choices" => [
                 %{
                   "index" => 0,
                   "delta" => %{
                     "role" => "assistant",
                     "content" => ""
                   },
                   "finish_reason" => "tool_calls"
                 }
               ]
             },
             %{
               "id" => "gen_1",
               "object" => "chat.completion.chunk",
               "created" => 1_777_000_001,
               "model" => "openai/gpt-5-mini",
               "provider" => "OpenRouter",
               "usage" => %{
                 "input_tokens" => 12,
                 "output_tokens" => 5
               },
               "choices" => [
                 %{
                   "index" => 0,
                   "delta" => %{
                     "role" => "assistant",
                     "content" => ""
                   },
                   "finish_reason" => "tool_calls"
                 }
               ]
             }
           ])}
        ]
      }

      {base_url, _agent} = start_scripted_server!(scripts)

      request_payload =
        RequestBuilder.build_chat_completions_payload(
          "openai/gpt-5-mini",
          %{},
          [%{"role" => "user", "content" => "Search for OpenAI"}],
          tools: [
            %{
              "type" => "function",
              "function" => %{
                "name" => "web__search_web",
                "description" => "Search the web",
                "parameters" => %{
                  "type" => "object",
                  "properties" => %{
                    "query" => %{"type" => "string"}
                  },
                  "required" => ["query"]
                }
              }
            }
          ]
        )

      events =
        run_and_capture_events!(Trace, %{
          base_url: base_url,
          api_key: "test-key",
          request_payload: request_payload,
          timeout_ms: 5_000,
          connect_timeout_ms: 5_000
        })

      assert Enum.any?(events, fn
               {:trace, {:append_text, "reasoning", :reasoning, 1, "Searching"}} -> true
               _other -> false
             end)

      assert Enum.any?(events, fn
               {:trace, {:set_text, "tc:call_1", :tool_call, 1, text}} ->
                 String.contains?(text, "Tool call: web__search_web") and
                   String.contains?(text, ~s({"query":"OpenAI"}))

               _other ->
                 false
             end)

      assert Enum.any?(events, fn
               {:trace, {:set_opaque, "tc:call_1", :tool_call, 10_000, opaque}} ->
                 opaque["tool_call_id"] == "call_1" and
                   opaque["name"] == "web__search_web" and
                   opaque["arguments"] == %{"query" => "OpenAI"} and
                   get_in(opaque, ["raw", "function", "arguments"]) == ~s({"query":"OpenAI"})

               _other ->
                 false
             end)

      assert [meta] = for({:response_complete, meta} <- events, do: meta)

      assert get_in(meta, [:raw_response, "choices", Access.at(0), "message", "tool_calls"]) == [
               %{
                 "id" => "call_1",
                 "type" => "function",
                 "function" => %{
                   "name" => "web__search_web",
                   "arguments" => ~s({"query":"OpenAI"})
                 }
               }
             ]
    end

    test "both chat adapters persist fragmented opaque-only reasoning details for replay" do
      chunk = fn delta, finish ->
        %{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]}
      end

      chunks =
        sse_chunks([
          chunk.(
            %{
              "reasoning" => "",
              "reasoning_details" => [
                %{"type" => "reasoning.encrypted", "id" => "r0", "index" => 2, "data" => "part-"}
              ]
            },
            nil
          ),
          chunk.(
            %{
              "reasoning_details" => [
                %{"type" => "reasoning.encrypted", "id" => "r0", "index" => 2, "data" => "one"},
                %{"type" => "reasoning.encrypted", "index" => 3, "data" => "two"}
              ]
            },
            nil
          ),
          chunk.(%{"content" => "Answer"}, "stop")
        ])

      {base_url, _agent} =
        start_scripted_server!(%{"/chat/completions" => [{200, chunks}, {200, chunks}]})

      for adapter <- [Trace, NvidiaBuildChatCompletion] do
        events =
          run_and_capture_events!(adapter, %{
            base_url: base_url,
            api_key: "k",
            context: %{provider_base_url: base_url, provider_api_key: "k"},
            request_payload: %{"model" => "test", "messages" => [], "stream" => true}
          })

        stored = RuntimeTrace.persistable(trace_step(events))
        reasoning = Enum.find(stored.items, &(&1.type == :reasoning))
        assert reasoning

        assert [%{kind: :opaque, content_json: %{"chat_completion_reasoning" => fields}}] =
                 reasoning.contents

        assert fields["reasoning_details"] == [
                 %{
                   "type" => "reasoning.encrypted",
                   "id" => "r0",
                   "index" => 2,
                   "data" => "part-one"
                 },
                 %{"type" => "reasoning.encrypted", "index" => 3, "data" => "two"}
               ]

        assert fields["reasoning"] == ""
        assert Map.has_key?(fields, "reasoning")

        history = [
          %{role: :assistant, llm_configuration_id: 4, steps: [Map.delete(stored, :raw_response)]}
        ]

        full = History.for_mode(history, :full, 4)
        [message] = ChatHistory.build_messages(full)
        assert message["reasoning_details"] == fields["reasoning_details"]
        assert message["content"] == "Answer"
      end
    end

    test "native reasoning and reasoning_content remain distinct from display text" do
      chunks =
        sse_chunks([
          %{
            "choices" => [
              %{"delta" => %{"reasoning" => "Reason ", "reasoning_content" => "Native "}}
            ]
          },
          %{
            "choices" => [
              %{
                "delta" => %{
                  "reasoning" => "one",
                  "reasoning_content" => "two",
                  "content" => "Answer"
                },
                "finish_reason" => "stop"
              }
            ]
          }
        ])

      {base_url, _agent} = start_scripted_server!(%{"/chat/completions" => [{200, chunks}]})

      events =
        run_and_capture_events!(Trace, %{
          base_url: base_url,
          api_key: "k",
          request_payload: %{"model" => "test", "messages" => [], "stream" => true}
        })

      assert Enum.any?(events, fn
               {:trace,
                {:set_opaque, "reasoning", :reasoning, 10_000,
                 %{"chat_completion_reasoning" => payload}}} ->
                 payload == %{"reasoning" => "Reason one", "reasoning_content" => "Native two"}

               _ ->
                 false
             end)
    end
  end
end
