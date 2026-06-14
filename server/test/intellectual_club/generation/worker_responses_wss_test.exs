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

    assert tool_followup_request["type"] == "response.create"
    assert tool_followup_request["previous_response_id"] == "resp_tool"

    assert [%{"type" => "function_call_output", "call_id" => "call_web_1"}] =
             tool_followup_request["input"]

    assert next_message_request["type"] == "response.create"
    refute Map.has_key?(next_message_request, "previous_response_id")
    assert is_list(next_message_request["input"])
    assert length(next_message_request["input"]) > length(tool_followup_request["input"])
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

  defp create_chat_with_web_tool!(actor, base_url) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "WSS provider #{System.unique_integer([:positive])}",
          type: :responses_wss,
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
          parameters: %{},
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

    {:ok, agent} =
      start_supervised(
        {Agent,
         fn ->
           %{
             scripts: scripts_fun.(base_url),
             requests: []
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

  defmodule ScriptedPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/responses"} = conn, opts) do
      agent = Keyword.fetch!(opts, :agent)

      conn
      |> WebSockAdapter.upgrade(__MODULE__.ScriptedSocket, %{agent: agent}, timeout: 60_000)
      |> halt()
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

        frames =
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

        {:push, Enum.map(frames, fn frame -> {:text, Jason.encode!(frame)} end), state}
      end

      @impl true
      def handle_info(_message, state), do: {:ok, state}
    end
  end
end
