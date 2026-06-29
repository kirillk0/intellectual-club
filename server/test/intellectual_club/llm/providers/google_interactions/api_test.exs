defmodule IntellectualClub.Llm.Providers.GoogleInteractions.ApiTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.GoogleInteractions.Api

  test "streams interaction events into trace and hydrated raw response steps" do
    scripts = %{
      "/interactions" => [
        {200,
         sse_chunks([
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

    {base_url, agent} = start_scripted_server!(scripts)

    events =
      run_and_capture_events!(%{
        base_url: base_url,
        api_key: "test-key",
        request_payload: %{
          "model" => "gemini-2.5-flash-lite",
          "input" => "Return exactly: pong",
          "stream" => true,
          "store" => false
        },
        timeout_ms: 1_000,
        connect_timeout_ms: 1_000
      })

    [request] = recorded_requests(agent, "/interactions")
    assert {"x-goog-api-key", "test-key"} in request.headers
    assert request.payload["store"] == false

    meta =
      Enum.find_value(events, fn
        {:response_complete, meta} -> meta
        _other -> nil
      end)

    assert meta.usage.input_tokens == 5
    assert meta.usage.output_tokens == 1
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

    runtime_step =
      Enum.reduce(events, RuntimeTrace.new_step(), fn
        {:trace, trace_event}, step -> RuntimeTrace.apply_event(step, trace_event)
        _event, step -> step
      end)

    assert RuntimeTrace.text_for_item_type(runtime_step, :reasoning) == "Need answer."
    assert RuntimeTrace.text_for_item_type(runtime_step, :answer) == "pong"
  end

  test "marks quota HTTP errors as retryable and preserves raw response" do
    scripts = %{
      "/interactions" => [
        {429,
         [
           Jason.encode!(%{
             "error" => %{
               "code" => "resource_exhausted",
               "message" => "Quota exceeded."
             }
           })
         ]}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)

    error =
      run_and_capture_error!(%{
        base_url: base_url,
        api_key: "test-key",
        request_payload: %{
          "model" => "gemini-2.5-flash-lite",
          "input" => "Hello",
          "stream" => true,
          "store" => false
        },
        timeout_ms: 1_000,
        connect_timeout_ms: 1_000
      })

    assert error.status_code == 429
    assert error.retryable == true
    assert error.error_text == "Quota exceeded."
    assert error.raw_response["status_code"] == 429
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

  defp run_and_capture_events!(opts) when is_map(opts) do
    parent = self()

    :ok =
      Api.stream_generate(opts, fn event ->
        send(parent, {:provider_event, event})
      end)

    drain_provider_events([])
  end

  defp drain_provider_events(acc) do
    receive do
      {:provider_event, event} -> drain_provider_events([event | acc])
    after
      0 -> Enum.reverse(acc)
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
        {Bandit, plug: {__MODULE__.ScriptedPlug, agent: agent}, scheme: :http, port: port}
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
      event_type = Map.get(object, "event_type", "message")
      "event: " <> event_type <> "\n" <> "data: " <> Jason.encode!(object) <> "\n\n"
    end) ++ ["event: done\ndata: [DONE]\n\n"]
  end

  defp recorded_requests(agent, path) when is_pid(agent) and is_binary(path) do
    Agent.get(agent, fn state -> Map.get(state.requests, path, []) end)
  end

  defmodule ScriptedPlug do
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

      content_type =
        if status_code >= 400 do
          "application/json"
        else
          "text/event-stream"
        end

      conn =
        conn
        |> put_resp_content_type(content_type)
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
