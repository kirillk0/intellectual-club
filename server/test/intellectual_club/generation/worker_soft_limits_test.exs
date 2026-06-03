defmodule IntellectualClub.Generation.WorkerSoftLimitsTest do
  use IntellectualClub.DataCase, async: false

  import Plug.Conn

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ToolInstance

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

  test "chat completions uses soft refusal when max tool rounds are exhausted" do
    tool_call = %{
      "id" => "call_web_1",
      "type" => "function",
      "function" => %{
        "name" => "web__read_url",
        "arguments" => Jason.encode!(%{"url" => "https://example.com"})
      }
    }

    refusal_text =
      "[tool error] Tool call limit reached (max_tool_rounds=0). " <>
        "Please proceed to the final answer using the information already available."

    scripts = %{
      "/chat/completions" => [
        {200,
         sse_chunks([
           %{
             "id" => "chatcmpl-tool",
             "object" => "chat.completion",
             "created" => 1,
             "model" => "test-chat-model",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => "",
                   "tool_calls" => [tool_call]
                 },
                 "finish_reason" => "tool_calls"
               }
             ],
             "usage" => %{
               "prompt_tokens" => 12,
               "completion_tokens" => 3,
               "prompt_tokens_details" => %{"cached_tokens" => 5},
               "completion_tokens_details" => %{"reasoning_tokens" => 2}
             }
           }
         ])},
        {200,
         sse_chunks([
           %{
             "id" => "chatcmpl-final",
             "object" => "chat.completion",
             "created" => 2,
             "model" => "test-chat-model",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => "Final answer from soft refusal."
                 },
                 "finish_reason" => "stop"
               }
             ],
             "usage" => %{
               "prompt_tokens" => 14,
               "completion_tokens" => 6,
               "prompt_tokens_details" => %{"cached_tokens" => 7},
               "completion_tokens_details" => %{"reasoning_tokens" => 4}
             }
           }
         ])}
      ]
    }

    %{user: actor} = user_fixture()
    {base_url, agent} = start_scripted_server!(scripts)

    chat =
      create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, max_tool_rounds: 0)

    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Need a web lookup", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    message_id = context.message_id
    assert_receive {:done, ^message_id}, 2_000

    message =
      wait_for_message!(message_id, actor, fn msg ->
        msg.status == :done and length(msg.steps) == 2
      end)

    assert message.status == :done
    assert message.error_detail in [nil, ""]
    assert message_answer_text(message) == "Final answer from soft refusal."
    assert refusal_text in tool_result_texts(message)

    [tool_step, final_step] = Enum.sort_by(message.steps, & &1.sequence)
    assert_soft_refusal_result_linked!(tool_step, refusal_text)

    assert tool_step.input_tokens == 12
    assert tool_step.output_tokens == 3
    assert tool_step.cached_input_tokens == 5
    assert tool_step.reasoning_tokens == 2

    assert final_step.input_tokens == 14
    assert final_step.output_tokens == 6
    assert final_step.cached_input_tokens == 7
    assert final_step.reasoning_tokens == 4

    requests = Agent.get(agent, & &1.requests)
    chat_requests = Map.get(requests, "/chat/completions", [])
    assert length(chat_requests) == 2

    [first_request, second_request] = chat_requests
    assert is_list(first_request["tools"])
    refute Map.has_key?(second_request, "tools")
    refute Map.has_key?(second_request, "tool_choice")

    assert Enum.any?(List.wrap(second_request["messages"]), fn msg ->
             msg["role"] == "tool" and msg["content"] == refusal_text and
               msg["tool_call_id"] == "call_web_1"
           end)
  end

  test "responses api uses soft refusal when context soft limit is reached" do
    tool_call = %{
      "id" => "fc_1",
      "type" => "function_call",
      "call_id" => "call_web_1",
      "name" => "web__read_url",
      "arguments" => Jason.encode!(%{"url" => "https://example.com"})
    }

    refusal_text =
      "[tool error] Context limit reached (7/10 > 5). " <>
        "Please proceed to the final answer using the information already available."

    scripts = %{
      "/responses" => [
        {200,
         sse_chunks([
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp-tool",
               "object" => "response",
               "model" => "test-responses-model",
               "output" => [tool_call],
               "usage" => %{
                 "input_tokens" => 4,
                 "output_tokens" => 3,
                 "input_tokens_details" => %{"cached_tokens" => 1},
                 "output_tokens_details" => %{"reasoning_tokens" => 2}
               }
             }
           }
         ])},
        {200,
         sse_chunks([
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp-final",
               "object" => "response",
               "model" => "test-responses-model",
               "output" => [
                 %{
                   "id" => "msg_1",
                   "type" => "message",
                   "role" => "assistant",
                   "status" => "completed",
                   "content" => [
                     %{
                       "type" => "output_text",
                       "text" => "Final answer after context soft limit refusal.",
                       "annotations" => []
                     }
                   ]
                 }
               ],
               "usage" => %{
                 "input_tokens" => 5,
                 "output_tokens" => 4,
                 "input_tokens_details" => %{"cached_tokens" => 2},
                 "output_tokens_details" => %{"reasoning_tokens" => 3}
               }
             }
           }
         ])}
      ]
    }

    %{user: actor} = user_fixture()
    {base_url, agent} = start_scripted_server!(scripts)

    chat =
      create_chat_with_tool!(actor, base_url, :responses,
        max_tool_rounds: 5,
        context_length: 10,
        context_soft_limit_percent: 50
      )

    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Need a web lookup", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    message_id = context.message_id
    assert_receive {:done, ^message_id}, 2_000

    message =
      wait_for_message!(message_id, actor, fn msg ->
        msg.status == :done and length(msg.steps) == 2
      end)

    assert message.status == :done
    assert message_answer_text(message) == "Final answer after context soft limit refusal."
    assert refusal_text in tool_result_texts(message)

    [tool_step, final_step] = Enum.sort_by(message.steps, & &1.sequence)
    assert_soft_refusal_result_linked!(tool_step, refusal_text, handoff_available: false)

    assert tool_step.input_tokens == 4
    assert tool_step.output_tokens == 3
    assert tool_step.cached_input_tokens == 1
    assert tool_step.reasoning_tokens == 2

    assert final_step.input_tokens == 5
    assert final_step.output_tokens == 4
    assert final_step.cached_input_tokens == 2
    assert final_step.reasoning_tokens == 3

    requests = Agent.get(agent, & &1.requests)
    responses_requests = Map.get(requests, "/responses", [])
    assert length(responses_requests) == 2

    [first_request, second_request] = responses_requests
    assert is_list(first_request["tools"])
    refute Map.has_key?(second_request, "tools")

    assert Enum.any?(List.wrap(second_request["input"]), fn item ->
             item["type"] == "function_call_output" and item["call_id"] == "call_web_1" and
               item["output"] == refusal_text
           end)
  end

  test "responses api keeps handoff available after context soft limit refusal" do
    tool_call = %{
      "id" => "fc_1",
      "type" => "function_call",
      "call_id" => "call_web_1",
      "name" => "web__read_url",
      "arguments" => Jason.encode!(%{"url" => "https://example.com"})
    }

    old_final_instruction =
      "Please proceed to the final answer using the information already available."

    refusal_text =
      "[tool error] Context limit reached (7/10 > 5). " <>
        "Non-handoff tools are no longer available. " <>
        "If more work is needed, call the available handoff tool with a continuation summary; " <>
        "otherwise provide the final answer using the information already available."

    scripts = %{
      "/responses" => [
        {200,
         sse_chunks([
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp-tool",
               "object" => "response",
               "model" => "test-responses-model",
               "output" => [tool_call],
               "usage" => %{
                 "input_tokens" => 4,
                 "output_tokens" => 3
               }
             }
           }
         ])},
        {200,
         sse_chunks([
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp-final",
               "object" => "response",
               "model" => "test-responses-model",
               "output" => [
                 %{
                   "id" => "msg_1",
                   "type" => "message",
                   "role" => "assistant",
                   "status" => "completed",
                   "content" => [
                     %{
                       "type" => "output_text",
                       "text" => "Use handoff if more work is needed.",
                       "annotations" => []
                     }
                   ]
                 }
               ],
               "usage" => %{
                 "input_tokens" => 5,
                 "output_tokens" => 4
               }
             }
           }
         ])}
      ]
    }

    %{user: actor} = user_fixture()
    {base_url, agent} = start_scripted_server!(scripts)

    chat =
      create_chat_with_tool!(actor, base_url, :responses,
        max_tool_rounds: 5,
        context_length: 10,
        context_soft_limit_percent: 50,
        handoff_tool?: true
      )

    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Need a web lookup", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    message_id = context.message_id
    assert_receive {:done, ^message_id}, 2_000

    message =
      wait_for_message!(message_id, actor, fn msg ->
        msg.status == :done and length(msg.steps) == 2
      end)

    assert message.status == :done
    assert message_answer_text(message) == "Use handoff if more work is needed."
    assert refusal_text in tool_result_texts(message)
    refute old_final_instruction in tool_result_texts(message)

    [tool_step, _final_step] = Enum.sort_by(message.steps, & &1.sequence)
    assert_soft_refusal_result_linked!(tool_step, refusal_text, handoff_available: true)

    requests = Agent.get(agent, & &1.requests)
    responses_requests = Map.get(requests, "/responses", [])
    assert length(responses_requests) == 2

    [first_request, second_request] = responses_requests
    assert "web__read_url" in request_tool_names(first_request)
    assert "agent_management__handoff" in request_tool_names(first_request)
    assert request_tool_names(second_request) == ["agent_management__handoff"]

    assert Enum.any?(List.wrap(second_request["input"]), fn item ->
             item["type"] == "function_call_output" and item["call_id"] == "call_web_1" and
               item["output"] == refusal_text
           end)

    refute Enum.any?(List.wrap(second_request["input"]), fn item ->
             item["type"] == "function_call_output" and
               String.contains?(to_string(item["output"] || ""), old_final_instruction)
           end)
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
      start_supervised({Bandit, plug: {ScriptedSSEPlug, agent: agent}, scheme: :http, port: port})

    {"http://127.0.0.1:#{port}", agent}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp sse_chunks(objects) when is_list(objects) do
    Enum.map(objects, fn object -> "data: " <> Jason.encode!(object) <> "\n\n" end) ++
      ["data: [DONE]\n\n"]
  end

  defp create_chat_with_tool!(actor, base_url, provider_type, opts) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Test provider #{System.unique_integer([:positive])}",
          type: provider_type,
          auth_method: :api_key,
          base_url: base_url,
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!()

    llm_configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "test-model",
          parameters: %{},
          timeout_seconds: 5,
          context_length: Keyword.get(opts, :context_length)
        },
        actor: actor
      )
      |> Ash.create!()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Agent bot #{System.unique_integer([:positive])}",
          first_messages: [],
          variables: %{},
          max_tool_rounds: Keyword.get(opts, :max_tool_rounds, 20),
          context_soft_limit_percent: Keyword.get(opts, :context_soft_limit_percent, 80),
          history_mode: :agent
        },
        actor: actor
      )
      |> Ash.create!()

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-web-reader",
          name: "Web reader",
          alias: "web",
          description: "",
          config: %{},
          secrets: %{},
          max_output_tokens: 20_000
        },
        actor: actor
      )
      |> Ash.create!()

    _binding =
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
      |> Ash.create!()

    if Keyword.get(opts, :handoff_tool?, false) do
      handoff_tool_instance =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "native-agent-management",
            name: "Agent management",
            alias: "agent_management",
            description: "",
            config: %{},
            secrets: %{},
            max_output_tokens: 20_000
          },
          actor: actor
        )
        |> Ash.create!()

      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: handoff_tool_instance.id,
          alias: "agent_management",
          sharing_mode: :shared,
          enabled: true,
          sequence: 1
        },
        actor: actor
      )
      |> Ash.create!()
    end

    Chat
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: "Soft limits chat",
        bot_id: bot.id,
        llm_configuration_id: llm_configuration.id,
        note: "",
        variables: %{}
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp request_tool_names(request) when is_map(request) do
    request
    |> Map.get("tools", [])
    |> List.wrap()
    |> Enum.map(fn tool ->
      get_in(tool, ["function", "name"]) || tool["name"]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp wait_for_message!(message_id, actor, predicate, timeout_ms \\ 2_000)
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
      maybe_wait_for_generation_worker_to_stop!(message_id, message)
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

  defp maybe_wait_for_generation_worker_to_stop!(message_id, %{status: status})
       when status in [:done, :error, :canceled, "done", "error", "canceled"] do
    wait_for_generation_worker_to_stop!(message_id)
  end

  defp maybe_wait_for_generation_worker_to_stop!(_message_id, _message), do: :ok

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

  defp tool_result_texts(message) do
    message
    |> Map.get(:steps, [])
    |> Enum.flat_map(&Map.get(&1, :items, []))
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&Map.get(&1, :contents, []))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map(&(&1.content_text || ""))
  end

  defp assert_soft_refusal_result_linked!(step, refusal_text, opts \\ []) do
    items = Map.get(step, :items, [])
    [tool_call] = Enum.filter(items, &(&1.type == :tool_call))
    [tool_result] = Enum.filter(items, &(&1.type == :tool_result))

    assert tool_result.tool_call_item_id == tool_call.id

    assert tool_result
           |> Map.get(:contents, [])
           |> Enum.any?(&(&1.kind == :text and &1.content_text == refusal_text))

    assert tool_result
           |> Map.get(:contents, [])
           |> Enum.any?(fn content ->
             content.kind == :opaque and
               get_in(content.content_json, ["tool_call_item_id"]) == tool_call.id
           end)

    case Keyword.fetch(opts, :handoff_available) do
      {:ok, expected} ->
        assert tool_result
               |> Map.get(:contents, [])
               |> Enum.any?(fn content ->
                 content.kind == :opaque and
                   get_in(content.content_json, ["raw", "handoff_available"]) == expected
               end)

      :error ->
        :ok
    end
  end
end
