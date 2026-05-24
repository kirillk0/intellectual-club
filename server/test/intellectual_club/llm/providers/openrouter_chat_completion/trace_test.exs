defmodule IntellectualClub.Llm.Providers.OpenRouterChatCompletion.TraceTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias IntellectualClub.Llm.Providers.Common.RequestBuilder
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion.Trace

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
    parent = self()

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

    :ok =
      Trace.stream_generate(
        %{
          base_url: base_url,
          api_key: "test-key",
          request_payload: request_payload,
          timeout_ms: 5_000,
          connect_timeout_ms: 5_000
        },
        fn event ->
          send(parent, {:provider_event, event})
        end
      )

    events = collect_provider_events([])

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

    {:response_complete, meta} =
      Enum.find(events, fn
        {:response_complete, _meta} -> true
        _other -> false
      end)

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

    wait_for_server!(port)

    {"http://127.0.0.1:#{port}", agent}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_for_server!(port) when is_integer(port) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_for_server!(port, deadline)
  end

  defp do_wait_for_server!(port, deadline) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 50) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Scripted SSE server did not start before timeout")
        else
          Process.sleep(5)
          do_wait_for_server!(port, deadline)
        end
    end
  end

  defp sse_chunks(objects) when is_list(objects) do
    Enum.map(objects, fn object -> "data: " <> Jason.encode!(object) <> "\n\n" end) ++
      ["data: [DONE]\n\n"]
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

      {response_chunks, status_code} =
        Agent.get_and_update(agent, fn state ->
          request_path = conn.request_path

          requests =
            Map.update(state.requests, request_path, [payload], fn existing ->
              existing ++ [payload]
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
