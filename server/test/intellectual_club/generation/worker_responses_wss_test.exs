defmodule IntellectualClub.Generation.WorkerResponsesWssTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ToolInstance

  test "responses_wss session is stateful within one assistant message and rebuilt for the next message" do
    %{user: actor} = user_fixture()

    {base_url, agent} =
      start_scripted_server!(fn base_url ->
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
      start_scripted_server!(fn base_url ->
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
             {"authorization", "Bearer test-key"} in headers
           end)
  end

  test "responses provider keeps HTTP selected for common retries after fallback" do
    previous_backoff =
      Application.get_env(:intellectual_club, :generation_auto_retry_backoff_ms)

    previous_jitter =
      Application.get_env(:intellectual_club, :generation_auto_retry_jitter_ratio)

    Application.put_env(:intellectual_club, :generation_auto_retry_backoff_ms, [0])
    Application.put_env(:intellectual_club, :generation_auto_retry_jitter_ratio, 0.0)

    on_exit(fn ->
      restore_env(:generation_auto_retry_backoff_ms, previous_backoff)
      restore_env(:generation_auto_retry_jitter_ratio, previous_jitter)
    end)

    %{user: actor} = user_fixture()

    {base_url, agent} =
      start_scripted_server!(fn _base_url ->
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
  end

  test "responses provider falls back to HTTP when WebSocket upgrade fails" do
    %{user: actor} = user_fixture()

    {base_url, agent} =
      start_scripted_server!(fn _base_url ->
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

  defp create_chat_with_web_tool!(actor, base_url, provider_type \\ :responses_wss) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "WSS provider #{System.unique_integer([:positive])}",
          type: provider_type,
          auth_method: :api_key,
          base_url: base_url,
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    llm_configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "test-model",
          parameters: %{"reasoning" => %{"summary" => "auto"}},
          temperature: 0,
          reasoning_effort: :low,
          timeout_seconds: 5
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "WSS bot #{System.unique_integer([:positive])}",
          first_messages: [],
          max_tool_rounds: 5,
          history_mode: :agent
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-web-reader",
          name: "Web reader",
          alias: "web",
          description: "",
          config: %{"http_timeout_seconds" => 2.0},
          secrets: %{},
          max_output_tokens: 20_000
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: tool_instance.id,
        alias: "web",
        sharing_mode: :shared,
        enabled: true,
        sequence: 0
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    Chat
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        llm_configuration_id: llm_configuration.id,
        note: ""
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp start_scripted_server!(scripts_fun) when is_function(scripts_fun, 1) do
    port = free_port()
    base_url = "http://127.0.0.1:#{port}"

    {websocket_scripts, http_scripts, reject_upgrade?} =
      case scripts_fun.(base_url) do
        %{websocket: :reject_upgrade, http: http_scripts} ->
          {[], http_scripts, true}

        %{websocket: websocket_scripts, http: http_scripts} ->
          {websocket_scripts, http_scripts, false}

        websocket_scripts when is_list(websocket_scripts) ->
          {websocket_scripts, [], false}
      end

    {:ok, agent} =
      start_supervised(
        {Agent,
         fn ->
           %{
             scripts: websocket_scripts,
             http_scripts: http_scripts,
             requests: [],
             http_requests: [],
             websocket_headers: [],
             http_headers: [],
             reject_upgrade?: reject_upgrade?
           }
         end}
      )

    {:ok, _server} =
      start_supervised(
        {Bandit, plug: {__MODULE__.ScriptedPlug, agent: agent}, scheme: :http, port: port}
      )

    wait_for_server!(port)
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
          flunk("Worker WSS test server did not start before timeout")
        else
          Process.sleep(5)
          do_wait_for_server!(port, deadline)
        end
    end
  end

  defp wait_for_message!(message_id, actor, predicate, timeout_ms \\ 5_000)
       when is_function(predicate, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_message(message_id, actor, predicate, deadline)
  end

  defp do_wait_for_message(message_id, actor, predicate, deadline) do
    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    if predicate.(message) do
      wait_for_generation_worker_to_stop!(message_id)
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_message(message_id, actor, predicate, deadline)
      else
        flunk("Condition was not met before timeout")
      end
    end
  end

  defp wait_for_generation_worker_to_stop!(message_id) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_for_generation_worker_to_stop!(message_id, deadline)
  end

  defp do_wait_for_generation_worker_to_stop!(message_id, deadline) do
    if GenerationSupervisor.get_generation_state(message_id) == :not_found do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_generation_worker_to_stop!(message_id, deadline)
      else
        flunk("Generation worker did not stop before timeout")
      end
    end
  end

  defp message_answer_text(message) do
    message
    |> Map.get(:steps, [])
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(&Map.get(&1, :items, []))
    |> Enum.filter(&(&1.type == :answer))
    |> Enum.flat_map(&Map.get(&1, :contents, []))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map_join("", fn content -> content.content_text || "" end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)

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
