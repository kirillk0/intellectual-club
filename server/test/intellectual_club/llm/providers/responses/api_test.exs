defmodule IntellectualClub.Llm.Providers.Responses.ApiTest do
  use ExUnit.Case, async: true

  import IntellectualClub.ProviderStreamHelpers
  import IntellectualClub.TestHttpServer

  import Plug.Conn

  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.Responses.Api
  alias IntellectualClub.Llm.Providers.Responses.Endpoint
  alias IntellectualClub.Llm.Providers.Responses.HttpPool

  @hydration_opts %{
    model_name: "gpt-4.1",
    request_payload: %{"model" => "gpt-4.1", "input" => [], "instructions" => ""},
    connect_timeout_ms: provider_deadline_ms()
  }

  @base_opts %{
    base_url: "http://127.0.0.1:9",
    api_key: "test-key",
    model_name: "gpt-4.1",
    timeout_ms: 200,
    connect_timeout_ms: 200
  }

  test "duplicates the current body cache key into session-id without changing the payload" do
    test_pid = self()

    handler = fn conn, _opts ->
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)
      assert get_req_header(conn, "session-id") == [payload["prompt_cache_key"]]
      assert get_req_header(conn, "thread-id") == []
      assert get_req_header(conn, "x-codex-turn-state") == []
      assert get_req_header(conn, "authorization") == ["Bearer test-key"]
      send(test_pid, {:wire_payload, payload})

      send_resp(
        conn,
        200,
        "data: " <>
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{"id" => "resp_session", "status" => "completed", "output" => []}
          }) <> "\n\n"
      )
    end

    {_base_url, port} = start_http_server!(handler)

    for key <- ["intellectual-club:user:1", "intellectual-club:user:2", "other-cache-key"] do
      payload = %{"model" => "test-model", "input" => [], "prompt_cache_key" => key}

      events =
        run_and_capture_events!(Api, %{
          base_url: "http://127.0.0.1:#{port}",
          api_key: "test-key",
          request_payload: payload,
          timeout_ms: provider_deadline_ms()
        })

      assert_receive {:wire_payload, ^payload}
      assert Enum.any?(events, &match?({:response_complete, %{raw_request: ^payload}}, &1))
    end
  end

  test "omits session-id for missing, empty or invalid body keys" do
    test_pid = self()

    handler = fn conn, _opts ->
      {:ok, body, conn} = read_body(conn)
      assert get_req_header(conn, "session-id") == []
      send(test_pid, {:wire_payload_without_session, Jason.decode!(body)})
      send_resp(conn, 400, Jason.encode!(%{"error" => %{"message" => "Test rejection"}}))
    end

    {_base_url, port} = start_http_server!(handler)

    for key <- [
          :missing,
          nil,
          "",
          " \t ",
          123,
          "bad\r\nheader",
          "bad\0header",
          "\u043a\u044d\u0448"
        ] do
      payload = %{"model" => "test-model", "input" => []}
      payload = if key == :missing, do: payload, else: Map.put(payload, "prompt_cache_key", key)

      error =
        run_and_capture_error!(Api, %{
          base_url: "http://127.0.0.1:#{port}",
          api_key: "test-key",
          request_payload: payload,
          timeout_ms: provider_deadline_ms()
        })

      assert_receive {:wire_payload_without_session, ^payload}
      assert error.status_code == 400
      assert error.raw_request == payload
    end
  end

  test "uses the dedicated Finch pool with the default connection timeout" do
    base_url = completed_response_server!("resp_pool")
    pool = Finch.Pool.new(base_url)
    assert Finch.find_pool(HttpPool, pool) == :error

    assert %{} = base_url |> stream_events!() |> response_complete!()
    assert {:ok, pool_pid} = Finch.find_pool(HttpPool, pool)
    assert is_pid(pool_pid)
  end

  test "preserves the provider identity supplied by the transport coordinator" do
    base_url = completed_response_server!("resp_legacy")

    events = stream_events!(base_url, %{provider: "responses_wss"})
    assert %{provider: "responses_wss"} = response_complete!(events)
  end

  test "connection failures echo the request payload unchanged" do
    for payload <- [
          %{"model" => "gpt-4.1", "input" => []},
          %{
            "model" => "gpt-4.1",
            "input" => [],
            "instructions" => "You are a careful assistant.",
            "store" => true
          }
        ] do
      error = run_and_capture_error!(Api, Map.put(@base_opts, :request_payload, payload))
      assert error.raw_request == payload
    end
  end

  test "hydrates completed response output from stream items when terminal response omits it" do
    scripts = %{
      "/responses" => [
        {200,
         sse_chunks([
           %{
             "type" => "response.output_item.added",
             "output_index" => 0,
             "item" => %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "content" => []
             }
           },
           %{
             "type" => "response.output_text.done",
             "item_id" => "msg_1",
             "output_index" => 0,
             "content_index" => 0,
             "text" => "Checking."
           },
           %{
             "type" => "response.output_item.added",
             "output_index" => 1,
             "item" => %{
               "id" => "fc_1",
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "web__read_url",
               "arguments" => ""
             }
           },
           %{
             "type" => "response.function_call_arguments.done",
             "item_id" => "fc_1",
             "output_index" => 1,
             "arguments" => ~s({"url":"https://example.com"})
           },
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_1",
               "object" => "response",
               "model" => "gpt-4.1",
               "status" => "completed",
               "usage" => %{
                 "input_tokens" => 3,
                 "output_tokens" => 2,
                 "total_tokens" => 5
               }
             }
           }
         ])}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)
    meta = base_url |> stream_events!(@hydration_opts) |> response_complete!()

    assert meta.usage == %{
             input_tokens: 3,
             output_tokens: 2,
             cached_input_tokens: nil,
             reasoning_tokens: nil,
             cost: nil,
             responses: %{
               "input_tokens" => 3,
               "output_tokens" => 2,
               "total_tokens" => 5
             }
           }

    assert meta.raw_response["output"] == [
             %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Checking."
                 }
               ]
             },
             %{
               "id" => "fc_1",
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "web__read_url",
               "arguments" => ~s({"url":"https://example.com"})
             }
           ]
  end

  test "merges stream output with terminal output by item id when indexes diverge" do
    scripts = %{
      "/responses" => [
        {200,
         sse_chunks([
           %{
             "type" => "response.output_item.added",
             "output_index" => 2,
             "item" => %{
               "id" => "rs_1",
               "type" => "reasoning",
               "summary" => []
             }
           },
           %{
             "type" => "response.reasoning_summary_text.done",
             "item_id" => "rs_1",
             "output_index" => 2,
             "summary_index" => 0,
             "text" => "Checked the sources."
           },
           %{
             "type" => "response.output_item.added",
             "output_index" => 3,
             "item" => %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "in_progress",
               "content" => []
             }
           },
           %{
             "type" => "response.output_text.done",
             "item_id" => "msg_1",
             "output_index" => 3,
             "content_index" => 0,
             "text" => "I found the relevant documentation."
           },
           %{
             "type" => "response.output_item.added",
             "output_index" => 4,
             "item" => %{
               "id" => "fc_1",
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "web__read_url",
               "arguments" => ""
             }
           },
           %{
             "type" => "response.function_call_arguments.done",
             "item_id" => "fc_1",
             "output_index" => 4,
             "arguments" => ~s({"url":"https://example.com"})
           },
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_shifted",
               "object" => "response",
               "model" => "gpt-4.1",
               "status" => "completed",
               "output" => [
                 %{
                   "id" => "rs_1",
                   "type" => "reasoning",
                   "summary" => []
                 },
                 %{
                   "id" => "msg_1",
                   "type" => "message",
                   "role" => "assistant",
                   "status" => "completed",
                   "content" => []
                 },
                 %{
                   "id" => "fc_1",
                   "type" => "function_call",
                   "call_id" => "call_1",
                   "name" => "web__read_url",
                   "arguments" => ~s({"url":"https://example.com"})
                 }
               ]
             }
           }
         ])}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)

    meta =
      base_url
      |> stream_events!(%{connect_timeout_ms: provider_deadline_ms()})
      |> response_complete!()

    assert meta.raw_response["output"] == [
             %{
               "id" => "rs_1",
               "type" => "reasoning",
               "summary" => [
                 %{"type" => "summary_text", "text" => "Checked the sources."}
               ]
             },
             %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "I found the relevant documentation."
                 }
               ]
             },
             %{
               "id" => "fc_1",
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "web__read_url",
               "arguments" => ~s({"url":"https://example.com"})
             }
           ]
  end

  test "prefers assembled stream output when terminal response output is partial" do
    scripts = %{
      "/responses" => [
        {200,
         sse_chunks([
           %{
             "type" => "response.output_item.added",
             "output_index" => 0,
             "item" => %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "in_progress",
               "content" => []
             }
           },
           %{
             "type" => "response.output_text.delta",
             "item_id" => "msg_1",
             "output_index" => 0,
             "content_index" => 0,
             "delta" => "Full "
           },
           %{
             "type" => "response.output_text.delta",
             "item_id" => "msg_1",
             "output_index" => 0,
             "content_index" => 0,
             "delta" => "answer."
           },
           %{
             "type" => "response.output_text.done",
             "item_id" => "msg_1",
             "output_index" => 0,
             "content_index" => 0,
             "text" => "Full answer."
           },
           %{
             "type" => "response.output_item.done",
             "output_index" => 0,
             "item" => %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Full answer.",
                   "annotations" => []
                 },
                 %{
                   "type" => "future_content",
                   "metadata" => %{"value" => 1}
                 }
               ]
             }
           },
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_1",
               "object" => "response",
               "model" => "gpt-4.1",
               "status" => "completed",
               "output" => [
                 %{
                   "id" => "msg_1",
                   "type" => "message",
                   "role" => "assistant",
                   "status" => "completed",
                   "content" => [
                     %{
                       "type" => "output_text",
                       "text" => "Full",
                       "annotations" => []
                     }
                   ]
                 }
               ]
             }
           }
         ])}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)

    events = stream_events!(base_url, @hydration_opts)
    meta = response_complete!(events)

    assert get_in(meta.raw_response, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             "Full answer."

    runtime_step = trace_step(events)

    assert RuntimeTrace.text_for_item_type(runtime_step, :answer) == "Full answer."

    answer_contents =
      runtime_step
      |> RuntimeTrace.persistable()
      |> Map.fetch!(:items)
      |> Enum.find(&(&1.type == :answer))
      |> Map.fetch!(:contents)

    assert Enum.any?(answer_contents, fn content ->
             content.kind == :opaque and content.content_json["type"] == "future_content"
           end)

    refute Enum.any?(answer_contents, fn content ->
             content.kind == :opaque and content.content_json["type"] == "message"
           end)
  end

  describe "incomplete responses" do
    for output_source <- [:terminal, :stream, :empty] do
      @tag output_source: output_source
      test "completes a token-limited response with #{output_source} output", %{
        output_source: output_source
      } do
        item = %{
          "id" => "msg_partial",
          "type" => "message",
          "role" => "assistant",
          "status" => "incomplete",
          "content" => [%{"type" => "output_text", "text" => "Partial answer"}]
        }

        response = %{
          "id" => "resp_incomplete",
          "status" => "incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"},
          "output" => if(output_source == :terminal, do: [item], else: []),
          "usage" => %{
            "input_tokens" => 12,
            "output_tokens" => 32,
            "output_tokens_details" => %{"reasoning_tokens" => 8}
          }
        }

        deltas =
          if output_source == :stream do
            [
              %{
                "type" => "response.output_item.added",
                "output_index" => 0,
                "item" => %{item | "content" => [], "status" => "in_progress"}
              },
              %{
                "type" => "response.output_text.delta",
                "item_id" => item["id"],
                "output_index" => 0,
                "content_index" => 0,
                "delta" => "Partial answer"
              }
            ]
          else
            []
          end

        {base_url, _agent} =
          start_scripted_server!(%{
            "/responses" => [
              {200,
               sse_chunks(deltas ++ [%{"type" => "response.incomplete", "response" => response}])}
            ]
          })

        events = stream_events!(base_url)
        meta = response_complete!(events)
        step = trace_step(events)

        refute Enum.any?(events, &match?({:response_error, _}, &1))
        assert step.response_final
        assert step.raw_response == meta.raw_response
        assert meta.raw_response["status"] == "incomplete"
        assert meta.raw_response["incomplete_details"] == %{"reason" => "max_output_tokens"}
        assert meta.usage.input_tokens == 12
        assert meta.usage.output_tokens == 32
        assert meta.usage.reasoning_tokens == 8

        if output_source == :empty do
          assert meta.raw_response["output"] == []
          assert RuntimeTrace.text_for_item_type(step, :answer) == ""
        else
          assert RuntimeTrace.text_for_item_type(step, :answer) == "Partial answer"
          assert [output] = meta.raw_response["output"]
          assert output["content"] == item["content"]
        end
      end
    end

    for reason <- ["content_filter", "future_reason", nil] do
      @tag reason: reason
      test "reports #{inspect(reason)} as a terminal provider error without retry", %{
        reason: reason
      } do
        response = %{
          "id" => "resp_incomplete",
          "status" => "incomplete",
          "incomplete_details" => if(reason, do: %{"reason" => reason}),
          "output" => []
        }

        {base_url, _agent} =
          start_scripted_server!(%{
            "/responses" => [
              {200, sse_chunks([%{"type" => "response.incomplete", "response" => response}])}
            ]
          })

        events = stream_events!(base_url)
        assert [error] = for({:response_error, meta} <- events, do: meta)
        refute Enum.any?(events, &match?({:response_complete, _}, &1))
        assert error.retryable == false
        assert error.error_kind == "provider"
        assert error.error_text == "Response incomplete: #{reason || "unknown"}"
        assert error.raw_response == response
      end
    end
  end

  describe "Endpoint.resolve/2" do
    for {url, opts, transport, http_base_url, websocket_base_url} <- [
          {nil, [], :http, "https://api.openai.com/v1", "wss://api.openai.com/v1"},
          {"http://example.com/api/", [], :http, "http://example.com/api",
           "ws://example.com/api"},
          {"https://example.com/api", [], :http, "https://example.com/api",
           "wss://example.com/api"},
          {"ws://example.com/api", [], :websocket, "http://example.com/api",
           "ws://example.com/api"},
          {"wss://example.com/api/", [], :websocket, "https://example.com/api",
           "wss://example.com/api"},
          {"https://api.openai.com/v1", [force_websocket?: true], :websocket,
           "https://api.openai.com/v1", "wss://api.openai.com/v1"}
        ] do
      @url url
      @opts opts
      @expected {transport, http_base_url, websocket_base_url}

      test "resolves #{inspect(url)} #{inspect(opts)} to #{transport}" do
        assert {:ok, endpoint} = Endpoint.resolve(@url, @opts)

        assert {endpoint.transport, endpoint.http_base_url, endpoint.websocket_base_url} ==
                 @expected
      end
    end

    test "rejects unsupported or hostless URLs" do
      assert {:error, :invalid_base_url} = Endpoint.resolve("ftp://example.com/v1")
      assert {:error, :invalid_base_url} = Endpoint.resolve("wss:///v1")
    end
  end

  describe "HttpPool" do
    test "starts a named Finch with the configured default pool" do
      assert is_pid(Process.whereis(HttpPool))

      assert %{
               id: HttpPool,
               start:
                 {Finch, :start_link,
                  [
                    [
                      name: HttpPool,
                      pools: %{
                        default: [
                          size: configured_size,
                          count: 1,
                          conn_opts: [transport_opts: [timeout: configured_timeout]]
                        ]
                      }
                    ]
                  ]}
             } = HttpPool.child_spec([])

      assert configured_size == HttpPool.pool_size()
      assert configured_timeout == HttpPool.connect_timeout_ms()
    end

    test "uses the named pool only for the standard connection timeout" do
      assert HttpPool.req_options(HttpPool.connect_timeout_ms()) == [finch: HttpPool]
      assert HttpPool.req_options(1_234) == [connect_options: [timeout: 1_234]]
      assert HttpPool.req_options(0) == [connect_options: [timeout: 0]]
    end
  end

  # Without `connect_timeout_ms` the request goes through the shared HttpPool.
  defp stream_events!(base_url, opts \\ %{}) do
    run_and_capture_events!(
      Api,
      Map.merge(
        %{
          base_url: base_url,
          api_key: "test-key",
          request_payload: %{"model" => "gpt-4.1", "input" => []},
          timeout_ms: provider_deadline_ms()
        },
        opts
      )
    )
  end

  defp completed_response_server!(response_id) do
    response = %{
      "id" => response_id,
      "object" => "response",
      "model" => "gpt-4.1",
      "status" => "completed",
      "output" => []
    }

    {base_url, _agent} =
      start_scripted_server!(%{
        "/responses" => [
          {200, sse_chunks([%{"type" => "response.completed", "response" => response}])}
        ]
      })

    base_url
  end

  defp response_complete!(events) do
    assert [meta] = for({:response_complete, meta} <- events, do: meta)
    meta
  end
end
