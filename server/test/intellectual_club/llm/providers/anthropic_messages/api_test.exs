defmodule IntellectualClub.Llm.Providers.AnthropicMessages.ApiTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.AnthropicMessages.Api

  test "sends Anthropic headers and streams text and tool calls into trace events" do
    scripts = %{
      "/messages" => [
        {200,
         sse_chunks([
           %{
             "type" => "message_start",
             "message" => %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "model" => "claude-sonnet-4-20250514",
               "content" => [],
               "stop_reason" => nil,
               "usage" => %{"input_tokens" => 10, "output_tokens" => 1}
             }
           },
           %{
             "type" => "content_block_start",
             "index" => 0,
             "content_block" => %{"type" => "text", "text" => ""}
           },
           %{
             "type" => "content_block_delta",
             "index" => 0,
             "delta" => %{"type" => "text_delta", "text" => "Checking."}
           },
           %{"type" => "content_block_stop", "index" => 0},
           %{
             "type" => "content_block_start",
             "index" => 1,
             "content_block" => %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "weather__get",
               "input" => %{}
             }
           },
           %{
             "type" => "content_block_delta",
             "index" => 1,
             "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"city":)}
           },
           %{
             "type" => "content_block_delta",
             "index" => 1,
             "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("Paris"})}
           },
           %{"type" => "content_block_stop", "index" => 1},
           %{
             "type" => "message_delta",
             "delta" => %{"stop_reason" => "tool_use", "stop_sequence" => nil},
             "usage" => %{"output_tokens" => 20}
           },
           %{"type" => "message_stop"}
         ])}
      ]
    }

    {base_url, agent} = start_scripted_server!(scripts)
    parent = self()

    request_payload = %{
      "model" => "claude-sonnet-4-20250514",
      "max_tokens" => 128,
      "messages" => [%{"role" => "user", "content" => [%{"type" => "text", "text" => "Hi"}]}],
      "stream" => true
    }

    :ok =
      Api.stream_generate(
        %{
          base_url: base_url,
          api_key: "test-key",
          request_payload: request_payload,
          timeout_ms: 1_000,
          connect_timeout_ms: 1_000
        },
        fn event ->
          send(parent, {:provider_event, event})
        end
      )

    [request] = recorded_requests(agent, "/messages")
    assert {"x-api-key", "test-key"} in request.headers
    assert {"anthropic-version", "2023-06-01"} in request.headers
    assert request.payload == request_payload

    events = collect_provider_events([])

    assert Enum.any?(events, fn
             {:trace, {:append_text, "answer", :answer, 1, "Checking."}} -> true
             _other -> false
           end)

    assert Enum.any?(events, fn
             {:trace, {:set_opaque, "tc:toolu_1", :tool_call, 10_000, opaque}} ->
               opaque["tool_call_id"] == "toolu_1" and
                 opaque["name"] == "weather__get" and
                 opaque["arguments"] == %{"city" => "Paris"} and
                 get_in(opaque, ["raw", "input"]) == %{"city" => "Paris"}

             _other ->
               false
           end)

    {:response_complete, meta} =
      Enum.find(events, fn
        {:response_complete, _meta} -> true
        _other -> false
      end)

    assert meta.raw_response["stop_reason"] == "tool_use"
    assert meta.raw_response["usage"] == %{"input_tokens" => 10, "output_tokens" => 20}

    assert meta.raw_response["content"] == [
             %{"type" => "text", "text" => "Checking."},
             %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "weather__get",
               "input" => %{"city" => "Paris"}
             }
           ]
  end

  test "does not classify first tool call after thinking as answer" do
    scripts = %{
      "/messages" => [
        {200,
         sse_chunks([
           %{
             "type" => "message_start",
             "message" => %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "model" => "claude-sonnet-4-20250514",
               "content" => [],
               "stop_reason" => nil,
               "usage" => %{"input_tokens" => 10, "output_tokens" => 1}
             }
           },
           %{
             "type" => "content_block_start",
             "index" => 0,
             "content_block" => %{"type" => "thinking", "thinking" => ""}
           },
           %{
             "type" => "content_block_delta",
             "index" => 0,
             "delta" => %{"type" => "thinking_delta", "thinking" => "Need data."}
           },
           %{"type" => "content_block_stop", "index" => 0},
           %{
             "type" => "content_block_start",
             "index" => 1,
             "content_block" => %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "weather__get",
               "input" => %{}
             }
           },
           %{
             "type" => "content_block_delta",
             "index" => 1,
             "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"city":"Paris"})}
           },
           %{"type" => "content_block_stop", "index" => 1},
           %{
             "type" => "message_delta",
             "delta" => %{"stop_reason" => "tool_use", "stop_sequence" => nil},
             "usage" => %{"output_tokens" => 20}
           },
           %{"type" => "message_stop"}
         ])}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)
    parent = self()

    :ok =
      Api.stream_generate(
        %{
          base_url: base_url,
          api_key: "test-key",
          request_payload: %{
            "model" => "claude-sonnet-4-20250514",
            "max_tokens" => 128,
            "messages" => [],
            "stream" => true
          },
          timeout_ms: 1_000,
          connect_timeout_ms: 1_000
        },
        fn event ->
          send(parent, {:provider_event, event})
        end
      )

    step =
      collect_provider_events([])
      |> Enum.reduce(RuntimeTrace.new_step(), fn
        {:trace, trace_event}, acc -> RuntimeTrace.apply_event(acc, trace_event)
        _event, acc -> acc
      end)

    items = RuntimeTrace.persistable(step).items
    sequences = Enum.map(items, & &1.sequence)

    assert Enum.map(items, &{&1.sequence, &1.type}) == [{1, "reasoning"}, {2, "tool_call"}]
    assert sequences == Enum.uniq(sequences)
    refute Enum.any?(items, &(&1.type == "answer"))
  end

  test "marks overloaded streamed provider errors as retryable" do
    scripts = %{
      "/messages" => [
        {200,
         sse_chunks([
           %{
             "type" => "error",
             "error" => %{
               "type" => "overloaded_error",
               "message" => "Overloaded"
             }
           }
         ])}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)

    error =
      run_and_capture_error!(%{
        base_url: base_url,
        api_key: "test-key",
        request_payload: %{
          "model" => "claude-sonnet-4-20250514",
          "max_tokens" => 128,
          "messages" => []
        },
        timeout_ms: 1_000,
        connect_timeout_ms: 1_000
      })

    assert error.retryable == true
    assert error.error_kind == "provider"
    assert error.error_text == "Overloaded"
  end

  test "includes HTTP status in non-JSON error raw response and marks 503 retryable" do
    body = "temporarily overloaded"

    scripts = %{
      "/messages" => [
        {503, [body]}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)

    error =
      run_and_capture_error!(%{
        base_url: base_url,
        api_key: "test-key",
        request_payload: %{
          "model" => "claude-sonnet-4-20250514",
          "max_tokens" => 128,
          "messages" => []
        },
        timeout_ms: 1_000,
        connect_timeout_ms: 1_000
      })

    assert error.status_code == 503
    assert error.retryable == true
    assert error.error_kind == "http"
    assert error.error_text == body

    assert error.raw_response == %{
             "raw_text" => body,
             "status_code" => 503
           }
  end

  defp run_and_capture_error!(opts) when is_map(opts) do
    parent = self()

    :ok =
      Api.stream_generate(opts, fn event ->
        send(parent, {:provider_event, event})
      end)

    assert_receive {:provider_event, {:response_error, error}}, 2_000
    error
  end

  defp collect_provider_events(acc) do
    receive do
      {:provider_event, event} ->
        collect_provider_events([event | acc])
    after
      0 ->
        Enum.reverse(acc)
    end
  end

  defp start_scripted_server!(scripts) when is_map(scripts) do
    {:ok, agent} =
      start_supervised(
        {Agent,
         fn ->
           %{
             scripts: scripts,
             requests: %{}
           }
         end}
      )

    port = free_port()

    {:ok, _server} =
      start_supervised(
        {Bandit, plug: {__MODULE__.ScriptedSSEPlug, agent: agent}, scheme: :http, port: port}
      )

    {"http://127.0.0.1:#{port}", agent}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp sse_chunks(objects) when is_list(objects) do
    Enum.map(objects, fn object ->
      "event: " <>
        to_string(object["type"] || object[:type]) <>
        "\n" <>
        "data: " <> Jason.encode!(object) <> "\n\n"
    end)
  end

  defp recorded_requests(agent, path) when is_pid(agent) and is_binary(path) do
    Agent.get(agent, fn state -> Map.get(state.requests, path, []) end)
  end

  defmodule ScriptedSSEPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, body, conn} = read_body(conn)

      payload =
        case Jason.decode(body) do
          {:ok, %{} = decoded} -> decoded
          _other -> %{"raw_body" => body}
        end

      request = %{
        headers: conn.req_headers,
        payload: payload
      }

      {response_chunks, status_code} =
        Agent.get_and_update(agent, fn state ->
          request_path = conn.request_path

          requests =
            Map.update(state.requests, request_path, [request], fn existing ->
              existing ++ [request]
            end)

          case Map.get(state.scripts, request_path, []) do
            [{code, chunks} | rest] ->
              {{chunks, code},
               %{state | scripts: Map.put(state.scripts, request_path, rest), requests: requests}}

            [] ->
              {{"No scripted response for #{request_path}", 500}, %{state | requests: requests}}
          end
        end)

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(status_code)

      Enum.reduce_while(List.wrap(response_chunks), conn, fn chunk, conn ->
        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end
  end
end
