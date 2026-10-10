defmodule IntellectualClub.Generation.WorkerResponsesWssTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  for transport <- [:http, :websocket] do
    @tag transport: transport
    test "#{transport} token-limited responses persist a completed partial answer without retry",
         %{
           transport: transport
         } do
      %{user: actor} = user_fixture()

      response = %{
        "id" => "resp_partial",
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "max_output_tokens"},
        "output" => [assistant_message("Partial answer.")],
        "usage" => %{"input_tokens" => 4, "output_tokens" => 32}
      }

      {base_url, agent} =
        start_wss_server!(fn _base_url ->
          script = [%{"type" => "response.incomplete", "response" => response}]

          case transport do
            :http -> %{websocket: [], http: [script]}
            :websocket -> [script]
          end
        end)

      provider_type = if transport == :http, do: :responses, else: :responses_wss
      chat = create_chat_with_web_tool!(actor, base_url, provider_type)
      Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

      {:ok, _user_message} =
        Threads.add_message_to_end(chat, :user, "Write a long answer", actor: actor)

      {:ok, context} = GenerationSupervisor.start_generation(chat.id, actor: actor)

      assert_receive {:done, message_id}, 10_000
      assert message_id == context.message_id
      message = wait_for_message!(message_id, actor, &(&1.status == :done))

      assert message.error_detail == nil
      assert message_answer_text(message) == "Partial answer."
      assert [step] = message.steps
      assert step.status == :done
      assert step.response_final
      assert step.input_tokens == 4
      assert step.output_tokens == 32
      assert Ash.load!(step, :raw_response, actor: actor).raw_response == response
      assert length(requests_for(agent)) + length(http_requests_for(agent)) == 1
    end
  end

  test "responses_wss session is stateful within one assistant message and rebuilt for the next message" do
    %{user: actor} = user_fixture()

    {base_url, agent} =
      start_wss_server!(fn base_url ->
        tool_url = base_url <> "/page"

        [
          [
            %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_tool",
                "object" => "response",
                "model" => "test-model",
                "status" => "completed",
                "output" => [
                  %{
                    "id" => "fc_1",
                    "type" => "function_call",
                    "call_id" => "call_web_1",
                    "name" => "web__read_url",
                    "arguments" => Jason.encode!(%{"url" => tool_url})
                  }
                ],
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3}
              }
            }
          ],
          [
            %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_final",
                "object" => "response",
                "model" => "test-model",
                "status" => "completed",
                "output" => [assistant_message("Final from WSS tool loop.")]
              }
            }
          ],
          [
            %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_next_message",
                "object" => "response",
                "model" => "test-model",
                "status" => "completed",
                "output" => [assistant_message("Second message final.")]
              }
            }
          ]
        ]
      end)

    chat = create_chat_with_web_tool!(actor, base_url)
    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Need a local page lookup", actor: actor)

    {:ok, first_context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    assert_receive {:done, first_message_id}, 10_000
    assert first_message_id == first_context.message_id

    first_message =
      wait_for_message!(first_message_id, actor, fn message ->
        message.status == :done and message_answer_text(message) == "Final from WSS tool loop."
      end)

    assert length(first_message.steps) == 2

    {:ok, _next_user_message} =
      Threads.add_message_to_end(chat, :user, "Now answer without tools", actor: actor)

    {:ok, second_context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    assert_receive {:done, second_message_id}, 10_000
    assert second_message_id == second_context.message_id

    _second_message =
      wait_for_message!(second_message_id, actor, fn message ->
        message.status == :done and message_answer_text(message) == "Second message final."
      end)

    [first_request, tool_followup_request, next_message_request] = requests_for(agent)

    assert first_request["type"] == "response.create"
    refute Map.has_key?(first_request, "previous_response_id")
    assert is_list(first_request["input"])
    assert length(first_request["input"]) >= 1
    assert first_request["temperature"] == 0
    assert first_request["reasoning"] == %{"effort" => "low", "summary" => "auto"}

    assert tool_followup_request["type"] == "response.create"
    assert tool_followup_request["previous_response_id"] == "resp_tool"

    assert [%{"type" => "function_call_output", "call_id" => "call_web_1"}] =
             tool_followup_request["input"]

    assert tool_followup_request["temperature"] == 0

    assert tool_followup_request["reasoning"] == %{
             "effort" => "low",
             "summary" => "auto"
           }

    assert next_message_request["type"] == "response.create"
    refute Map.has_key?(next_message_request, "previous_response_id")
    assert is_list(next_message_request["input"])
    assert length(next_message_request["input"]) > length(tool_followup_request["input"])
    assert next_message_request["temperature"] == 0
    assert next_message_request["reasoning"] == %{"effort" => "low", "summary" => "auto"}
  end

  test "responses provider falls back from close 1009 to HTTP for the whole tool loop" do
    %{user: actor} = user_fixture()

    {base_url, agent} =
      start_wss_server!(fn base_url ->
        tool_url = base_url <> "/page"

        %{
          websocket: [{:close, 1009, "message too big"}],
          http: [
            [
              %{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_http_tool",
                  "object" => "response",
                  "model" => "test-model",
                  "status" => "completed",
                  "output" => [
                    %{
                      "id" => "fc_http_1",
                      "type" => "function_call",
                      "call_id" => "call_http_1",
                      "name" => "web__read_url",
                      "arguments" => Jason.encode!(%{"url" => tool_url})
                    }
                  ]
                }
              }
            ],
            [
              %{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_http_final",
                  "object" => "response",
                  "model" => "test-model",
                  "status" => "completed",
                  "output" => [assistant_message("Final after HTTP fallback.")]
                }
              }
            ]
          ]
        }
      end)

    websocket_base_url = String.replace_prefix(base_url, "http://", "ws://")
    chat = create_chat_with_web_tool!(actor, websocket_base_url, :responses)
    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Use the local page", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    assert_receive {:done, message_id}, 10_000
    assert message_id == context.message_id

    message =
      wait_for_message!(message_id, actor, fn message ->
        message.status == :done and
          message_answer_text(message) == "Final after HTTP fallback."
      end)

    assert message.steps |> Enum.sort_by(& &1.sequence) |> Enum.map(& &1.status) == [:done, :done]

    [websocket_request] = requests_for(agent)
    [first_http_request, tool_http_request] = http_requests_for(agent)

    assert websocket_request["type"] == "response.create"
    refute Map.has_key?(websocket_request, "stream")

    assert first_http_request["stream"] == true
    refute Map.has_key?(first_http_request, "type")
    refute Map.has_key?(first_http_request, "previous_response_id")
    assert is_list(first_http_request["input"])

    assert tool_http_request["stream"] == true
    refute Map.has_key?(tool_http_request, "type")
    refute Map.has_key?(tool_http_request, "previous_response_id")
    assert length(tool_http_request["input"]) > length(first_http_request["input"])
    assert Enum.any?(tool_http_request["input"], &(&1["type"] == "function_call"))

    assert Enum.any?(
             tool_http_request["input"],
             &(&1["type"] == "function_call_output" and &1["call_id"] == "call_http_1")
           )

    assert Enum.all?(websocket_headers_for(agent), fn headers ->
             {"authorization", "Bearer test-key"} in headers
           end)

    assert Enum.all?(http_headers_for(agent), fn headers ->
             {"authorization", "Bearer test-key"} in headers and
               {"session-id", "intellectual-club:user:#{actor.id}"} in headers
           end)

    assert first_http_request["prompt_cache_key"] == "intellectual-club:user:#{actor.id}"
    assert tool_http_request["prompt_cache_key"] == first_http_request["prompt_cache_key"]
  end

  test "responses provider keeps HTTP selected for common retries after fallback" do
    put_app_env(:generation_auto_retry_backoff_ms, [0])
    put_app_env(:generation_auto_retry_jitter_ratio, 0.0)

    %{user: actor} = user_fixture()

    {base_url, agent} =
      start_wss_server!(fn _base_url ->
        %{
          websocket: [{:close, 1009, "message too big"}],
          http: [
            [
              %{
                "type" => "error",
                "error" => %{
                  "code" => "server_is_overloaded",
                  "type" => "service_unavailable_error",
                  "message" => "Retry over HTTP"
                }
              }
            ],
            [
              %{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_http_retry",
                  "object" => "response",
                  "model" => "test-model",
                  "status" => "completed",
                  "output" => [assistant_message("Recovered over HTTP.")]
                }
              }
            ]
          ]
        }
      end)

    websocket_base_url = String.replace_prefix(base_url, "http://", "ws://")
    chat = create_chat_with_web_tool!(actor, websocket_base_url, :responses)
    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Retry if needed", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    assert_receive {:done, message_id}, 10_000
    assert message_id == context.message_id

    message =
      wait_for_message!(message_id, actor, fn message ->
        message.status == :done and message_answer_text(message) == "Recovered over HTTP."
      end)

    assert message.steps |> Enum.sort_by(& &1.sequence) |> Enum.map(& &1.status) == [
             :error,
             :done
           ]

    assert length(requests_for(agent)) == 1
    assert length(http_requests_for(agent)) == 2

    assert Enum.all?(http_headers_for(agent), fn headers ->
             {"session-id", "intellectual-club:user:#{actor.id}"} in headers
           end)

    assert Enum.all?(http_requests_for(agent), fn payload ->
             payload["prompt_cache_key"] == "intellectual-club:user:#{actor.id}"
           end)
  end

  test "responses provider falls back to HTTP when WebSocket upgrade fails" do
    %{user: actor} = user_fixture()

    {base_url, agent} =
      start_wss_server!(fn _base_url ->
        %{
          websocket: :reject_upgrade,
          http: [
            [
              %{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_http_handshake",
                  "object" => "response",
                  "model" => "test-model",
                  "status" => "completed",
                  "output" => [assistant_message("Recovered after failed upgrade.")]
                }
              }
            ]
          ]
        }
      end)

    websocket_base_url = String.replace_prefix(base_url, "http://", "ws://")
    chat = create_chat_with_web_tool!(actor, websocket_base_url, :responses)
    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Handle the failed upgrade", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    assert_receive {:done, message_id}, 10_000
    assert message_id == context.message_id

    message =
      wait_for_message!(message_id, actor, fn message ->
        message.status == :done and
          message_answer_text(message) == "Recovered after failed upgrade."
      end)

    assert message.steps |> Enum.map(& &1.status) == [:done]
    assert requests_for(agent) == []
    assert length(websocket_headers_for(agent)) == 1
    assert length(http_requests_for(agent)) == 1
  end

  defp assistant_message(text) when is_binary(text) do
    %{
      "id" => "msg_" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }
  end

  # A chat with an agent-mode bot bound to a web reader tool, configured for
  # a Responses provider (`provider_type`) at `base_url`.
  defp create_chat_with_web_tool!(actor, base_url, provider_type \\ :responses_wss) do
    configuration =
      create_configuration!(actor, %{
        model_name: "test-model",
        parameters: %{"reasoning" => %{"summary" => "auto"}},
        temperature: 0,
        reasoning_effort: :low,
        timeout_seconds: 5,
        context_length: nil,
        provider_attrs: %{type: provider_type, base_url: base_url}
      })

    bot = create_bot!(actor, %{max_tool_rounds: 5, history_mode: :agent})

    tool =
      create_tool_instance!(actor, %{
        type: "native-web-reader",
        name: "Web reader",
        alias: "web",
        description: "",
        config: %{"http_timeout_seconds" => 2.0},
        max_output_tokens: 20_000
      })

    create_bot_tool_binding!(actor, bot, tool, %{alias: "web"})
    create_chat!(actor, %{bot_id: bot.id, llm_configuration_id: configuration.id})
  end

  defp start_wss_server!(scripts_fun) when is_function(scripts_fun, 1) do
    # The scripts may embed the server URL, so the server starts first and the
    # plug reads its state only when a request arrives.
    {:ok, agent} = start_supervised({Agent, fn -> nil end})
    {base_url, _port} = start_http_server!({__MODULE__.ScriptedPlug, agent: agent})

    {websocket_scripts, http_scripts, reject_upgrade?} =
      case scripts_fun.(base_url) do
        %{websocket: :reject_upgrade, http: http_scripts} ->
          {[], http_scripts, true}

        %{websocket: websocket_scripts, http: http_scripts} ->
          {websocket_scripts, http_scripts, false}

        websocket_scripts when is_list(websocket_scripts) ->
          {websocket_scripts, [], false}
      end

    Agent.update(agent, fn nil ->
      %{
        scripts: websocket_scripts,
        http_scripts: http_scripts,
        requests: [],
        http_requests: [],
        websocket_headers: [],
        http_headers: [],
        reject_upgrade?: reject_upgrade?
      }
    end)

    {base_url, agent}
  end

  defp requests_for(agent) do
    Agent.get(agent, & &1.requests)
  end

  defp http_requests_for(agent) do
    Agent.get(agent, & &1.http_requests)
  end

  defp websocket_headers_for(agent) do
    Agent.get(agent, & &1.websocket_headers)
  end

  defp http_headers_for(agent) do
    Agent.get(agent, & &1.http_headers)
  end

  defp wait_for_message!(message_id, actor, predicate, timeout_ms \\ 5_000)
       when is_function(predicate, 1) do
    message =
      wait_until(
        fn ->
          message =
            Ash.get!(ChatMessage, message_id, actor: actor, load: [steps: [items: [:contents]]])

          predicate.(message) && message
        end,
        timeout: timeout_ms,
        interval: 20
      )

    wait_for_generation_worker_to_stop!(message_id)
    message
  end

  defmodule ScriptedPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/responses", method: "POST"} = conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      frames =
        Agent.get_and_update(agent, fn state ->
          {script, rest} =
            case state.http_scripts do
              [next | rest] -> {next, rest}
              [] -> {[%{"type" => "error", "error" => %{"message" => "No HTTP script"}}], []}
            end

          next_state = %{
            state
            | http_scripts: rest,
              http_requests: state.http_requests ++ [request],
              http_headers: state.http_headers ++ [conn.req_headers]
          }

          {script, next_state}
        end)

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      Enum.reduce(frames, conn, fn frame, conn ->
        {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(frame) <> "\n\n")
        conn
      end)
    end

    def call(%{request_path: "/responses"} = conn, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(agent, fn state ->
        %{state | websocket_headers: state.websocket_headers ++ [conn.req_headers]}
      end)

      if Agent.get(agent, & &1.reject_upgrade?) do
        send_resp(conn, 426, "upgrade rejected")
      else
        conn
        |> WebSockAdapter.upgrade(__MODULE__.ScriptedSocket, %{agent: agent}, timeout: 60_000)
        |> halt()
      end
    end

    def call(%{request_path: "/page"} = conn, _opts) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(
        200,
        "<html><body><main>Local page body for WSS worker test.</main></body></html>"
      )
    end

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "not found")
    end

    defmodule ScriptedSocket do
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
          {:close, code, reason} ->
            {:stop, :normal, {code, reason}, state}

          frames when is_list(frames) ->
            {:push, Enum.map(frames, fn frame -> {:text, Jason.encode!(frame)} end), state}
        end
      end

      @impl true
      def handle_info(_message, state), do: {:ok, state}
    end
  end
end
