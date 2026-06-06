defmodule IntellectualClub.Llm.Providers.ResponsesWss.SessionTest do
  use ExUnit.Case, async: false

  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.ResponsesWss.Session

  test "first wire payload is response.create without HTTP stream fields" do
    payload = %{
      "model" => "gpt-4.1",
      "input" => [],
      "instructions" => "Be precise.",
      "stream" => true,
      "background" => false,
      "store" => false
    }

    assert {:ok, wire} = Session.wire_payload(payload, base_session_state())

    assert wire == %{
             "type" => "response.create",
             "model" => "gpt-4.1",
             "input" => [],
             "instructions" => "Be precise.",
             "store" => false
           }
  end

  test "follow-up wire payload uses previous_response_id and only delta input" do
    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "Hi"}]
      }
    ]

    output = [
      %{
        "id" => "fc_1",
        "type" => "function_call",
        "call_id" => "call_1",
        "name" => "web__read_url",
        "arguments" => "{}"
      }
    ]

    delta = [
      %{
        "type" => "function_call_output",
        "call_id" => "call_1",
        "output" => "Tool result"
      }
    ]

    previous_request = %{"model" => "gpt-4.1", "input" => input, "store" => false}

    current_request = %{
      "model" => "gpt-4.1",
      "input" => input ++ output ++ delta,
      "store" => false
    }

    state =
      base_session_state()
      |> Map.put(:last_request, previous_request)
      |> Map.put(:last_response, %{"id" => "resp_1", "output" => output})

    assert {:ok, wire} = Session.wire_payload(current_request, state)

    assert wire["previous_response_id"] == "resp_1"
    assert wire["input"] == delta
  end

  test "follow-up wire payload falls back to full input when non-input fields change" do
    input = [%{"type" => "message", "role" => "user", "content" => []}]
    output = [%{"id" => "msg_1", "type" => "message", "role" => "assistant", "content" => []}]

    delta = [
      %{"type" => "function_call_output", "call_id" => "call_1", "output" => "Tool result"}
    ]

    state =
      base_session_state()
      |> Map.put(:last_request, %{"model" => "gpt-4.1", "input" => input, "instructions" => "A"})
      |> Map.put(:last_response, %{"id" => "resp_1", "output" => output})

    current_request = %{
      "model" => "gpt-4.1",
      "input" => input ++ output ++ delta,
      "instructions" => "B"
    }

    assert {:ok, wire} = Session.wire_payload(current_request, state)

    refute Map.has_key?(wire, "previous_response_id")
    assert wire["input"] == current_request["input"]
  end

  test "streams websocket text frames through shared Responses event reducer" do
    scripts = [
      [
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
          "delta" => "Hello "
        },
        %{
          "type" => "response.output_text.done",
          "item_id" => "msg_1",
          "output_index" => 0,
          "content_index" => 0,
          "text" => "Hello world."
        },
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_1",
            "object" => "response",
            "model" => "gpt-4.1",
            "status" => "completed",
            "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
          }
        }
      ]
    ]

    {base_url, agent} = start_scripted_server!(scripts)
    payload = %{"model" => "gpt-4.1", "input" => [], "stream" => true}

    events = run_session_and_capture_events!(base_url, [payload])

    assert {:response_complete, meta} =
             Enum.find(events, fn
               {:response_complete, _meta} -> true
               _other -> false
             end)

    assert meta.provider == "responses_wss"
    assert meta.raw_request == payload

    assert meta.raw_response["output"] == [
             %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "in_progress",
               "content" => [%{"type" => "output_text", "text" => "Hello world."}]
             }
           ]

    runtime_step =
      Enum.reduce(events, RuntimeTrace.new_step(), fn
        {:trace, trace_event}, step -> RuntimeTrace.apply_event(step, trace_event)
        _event, step -> step
      end)

    assert RuntimeTrace.text_for_item_type(runtime_step, :answer) == "Hello world."

    [wire_request] = requests_for(agent)
    assert wire_request["type"] == "response.create"
    refute Map.has_key?(wire_request, "stream")
    assert beta_headers_for(agent) == [["responses_websockets=2026-02-06"]]
  end

  test "successful follow-up over same session sends previous_response_id and delta input" do
    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "Use a tool"}]
      }
    ]

    tool_call = %{
      "id" => "fc_1",
      "type" => "function_call",
      "call_id" => "call_1",
      "name" => "web__read_url",
      "arguments" => "{}"
    }

    tool_result = %{"type" => "function_call_output", "call_id" => "call_1", "output" => "Done"}

    scripts = [
      [
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_1",
            "object" => "response",
            "model" => "gpt-4.1",
            "status" => "completed",
            "output" => [tool_call]
          }
        }
      ],
      [
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_2",
            "object" => "response",
            "model" => "gpt-4.1",
            "status" => "completed",
            "output" => [
              %{
                "id" => "msg_1",
                "type" => "message",
                "role" => "assistant",
                "content" => [%{"type" => "output_text", "text" => "Final."}]
              }
            ]
          }
        }
      ]
    ]

    {base_url, agent} = start_scripted_server!(scripts)

    run_session_and_capture_events!(base_url, [
      %{"model" => "gpt-4.1", "input" => input, "store" => false},
      %{"model" => "gpt-4.1", "input" => input ++ [tool_call, tool_result], "store" => false}
    ])

    [first_request, second_request] = requests_for(agent)

    refute Map.has_key?(first_request, "previous_response_id")
    assert first_request["input"] == input

    assert second_request["previous_response_id"] == "resp_1"
    assert second_request["input"] == [tool_result]
  end

  test "previous_response_not_found is retryable and resets session state" do
    input = [%{"type" => "message", "role" => "user", "content" => []}]

    tool_call = %{
      "id" => "fc_1",
      "type" => "function_call",
      "call_id" => "call_1",
      "name" => "web__read_url",
      "arguments" => "{}"
    }

    tool_result = %{"type" => "function_call_output", "call_id" => "call_1", "output" => "Done"}
    followup_input = input ++ [tool_call, tool_result]

    scripts = [
      [
        %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_1", "status" => "completed", "output" => [tool_call]}
        }
      ],
      [
        %{
          "type" => "error",
          "status" => 400,
          "error" => %{
            "code" => "previous_response_not_found",
            "message" => "Previous response not found."
          }
        }
      ],
      [
        %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_2", "status" => "completed", "output" => []}
        }
      ]
    ]

    {base_url, agent} = start_scripted_server!(scripts)

    events =
      run_session_and_capture_events!(base_url, [
        %{"model" => "gpt-4.1", "input" => input},
        %{"model" => "gpt-4.1", "input" => followup_input},
        %{"model" => "gpt-4.1", "input" => followup_input}
      ])

    assert {:response_error, error} =
             Enum.find(events, fn
               {:response_error, _meta} -> true
               _other -> false
             end)

    assert error.provider == "responses_wss"
    assert error.retryable == true
    assert error.raw_request["input"] == followup_input

    [_first_request, second_request, third_request] = requests_for(agent)
    assert second_request["previous_response_id"] == "resp_1"
    assert second_request["input"] == [tool_result]
    refute Map.has_key?(third_request, "previous_response_id")
    assert third_request["input"] == followup_input
  end

  test "close before response.completed emits retryable transport error" do
    {base_url, _agent} = start_scripted_server!([:close])

    events = run_session_and_capture_events!(base_url, [%{"model" => "gpt-4.1", "input" => []}])

    assert {:response_error, error} =
             Enum.find(events, fn
               {:response_error, _meta} -> true
               _other -> false
             end)

    assert error.provider == "responses_wss"
    assert error.retryable == true
    assert error.error_kind in ["network", "timeout", "transport"]
  end

  defp base_session_state do
    %{
      context: %{},
      connection: nil,
      last_request: nil,
      last_response: nil
    }
  end

  defp run_session_and_capture_events!(base_url, payloads) when is_list(payloads) do
    parent = self()
    {:ok, session} = Session.start(%{provider_type: "responses_wss"})
    on_exit(fn -> Session.stop(session) end)

    Enum.each(payloads, fn payload ->
      :ok =
        Session.stream_generate(
          session,
          %{
            base_url: base_url,
            api_key: "test-key",
            request_payload: payload,
            timeout_ms: 1_000,
            connect_timeout_ms: 1_000,
            provider: "responses_wss"
          },
          fn event -> send(parent, {:provider_event, event}) end
        )
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

  defp start_scripted_server!(scripts) when is_list(scripts) do
    {:ok, agent} =
      start_supervised(
        {Agent,
         fn ->
           %{
             scripts: scripts,
             requests: [],
             beta_headers: []
           }
         end}
      )

    port = free_port()

    {:ok, _server} =
      start_supervised(
        {Bandit, plug: {__MODULE__.ScriptedWssPlug, agent: agent}, scheme: :http, port: port}
      )

    wait_for_server!(port)
    {"http://127.0.0.1:#{port}", agent}
  end

  defp requests_for(agent) do
    Agent.get(agent, & &1.requests)
  end

  defp beta_headers_for(agent) do
    Agent.get(agent, & &1.beta_headers)
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
          flunk("WebSocket test server did not start before timeout")
        else
          Process.sleep(5)
          do_wait_for_server!(port, deadline)
        end
    end
  end

  defmodule ScriptedWssPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/responses"} = conn, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(agent, fn state ->
        beta =
          conn.req_headers
          |> Enum.filter(fn {key, _value} -> String.downcase(key) == "openai-beta" end)
          |> Enum.map(fn {_key, value} -> value end)

        %{state | beta_headers: state.beta_headers ++ [beta]}
      end)

      conn
      |> WebSockAdapter.upgrade(__MODULE__.ScriptedWssSocket, %{agent: agent}, timeout: 60_000)
      |> halt()
    end

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "not found")
    end

    defmodule ScriptedWssSocket do
      @behaviour WebSock

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_in({payload, [opcode: :text]}, %{agent: agent} = state) do
        request = Jason.decode!(payload)

        reply =
          Agent.get_and_update(agent, fn state ->
            {script, rest} =
              case state.scripts do
                [next | rest] ->
                  {next, rest}

                [] ->
                  {[%{"type" => "error", "error" => %{"message" => "No scripted response"}}], []}
              end

            {script, %{state | scripts: rest, requests: state.requests ++ [request]}}
          end)

        case reply do
          :close ->
            {:stop, :normal, state}

          frames when is_list(frames) ->
            {:push, Enum.map(frames, fn frame -> {:text, Jason.encode!(frame)} end), state}
        end
      end

      @impl true
      def handle_info(_message, state), do: {:ok, state}
    end
  end
end
