defmodule IntellectualClub.Generation.WorkerToolsTest do
  @moduledoc """
  Worker tool rounds against scripted provider servers: concurrent tool
  execution, the tool round limit and context soft limit (soft refusals), and
  the handoff tool.
  """
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.Tools.RateLimiter
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  defmodule ConcurrentMcpPlug do
    import Plug.Conn

    @tool_call_release_timeout_ms 10_000

    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)

      case payload["method"] do
        "initialize" ->
          response = %{
            "jsonrpc" => "2.0",
            "id" => payload["id"],
            "result" => %{"capabilities" => %{}}
          }

          conn
          |> put_resp_header("mcp-session-id", "test-session")
          |> put_resp_content_type("text/event-stream")
          |> send_resp(200, sse(response))

        "tools/call" ->
          tool_name = get_in(payload, ["params", "name"])
          send(test_pid, {:tool_call_entered, self(), tool_name})

          receive do
            :release_tool_call -> :ok
          after
            @tool_call_release_timeout_ms -> send(test_pid, {:tool_call_wait_timeout, tool_name})
          end

          response = %{
            "jsonrpc" => "2.0",
            "id" => payload["id"],
            "result" => %{
              "content" => [%{"type" => "text", "text" => "result #{tool_name}"}]
            }
          }

          conn
          |> put_resp_content_type("text/event-stream")
          |> send_resp(200, sse(response))

        other ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(500, "Unsupported method: #{inspect(other)}")
      end
    end

    defp sse(object), do: "data: " <> Jason.encode!(object) <> "\n\n"
  end

  describe "tool execution" do
    test "execute_tool_calls runs a batch concurrently and preserves result order" do
      RateLimiter.reset()
      {server_url, _port} = start_http_server!({ConcurrentMcpPlug, test_pid: self()})

      tool = %ToolInstance{
        id: System.unique_integer([:positive, :monotonic]),
        type: "mcp-http",
        config: %{"server_url" => server_url},
        secrets: %{},
        max_output_tokens: 20_000
      }

      calls = [
        %{
          call_id: "call_second",
          name: "web__second",
          args: %{},
          raw: %{"id" => "call_second"}
        },
        %{
          call_id: "call_first",
          name: "web__first",
          args: %{},
          raw: %{"id" => "call_first"}
        }
      ]

      task = Task.async(fn -> Worker.execute_tool_calls(calls, %{"web" => tool}, nil) end)

      entered =
        Enum.map(1..2, fn _ ->
          receive do
            {:tool_call_entered, pid, tool_name} -> {pid, tool_name}
            {:tool_call_wait_timeout, tool_name} -> flunk("Tool call timed out: #{tool_name}")
          after
            5_000 -> flunk("Expected both tool calls to enter execution concurrently")
          end
        end)

      assert entered |> Enum.map(&elem(&1, 1)) |> Enum.sort() == ["first", "second"]

      Enum.each(entered, fn {pid, _tool_name} -> send(pid, :release_tool_call) end)

      results = Task.await(task, 5_000)

      assert Enum.map(results, & &1.call_id) == ["call_second", "call_first"]
      assert Enum.map(results, & &1.text) == ["result second", "result first"]
    end

    test "worker continues generation after a linked tool task exits normally" do
      tool_call = %{
        "id" => "call_random_1",
        "type" => "function",
        "function" => %{
          "name" => "game__random_select",
          "arguments" =>
            Jason.encode!(%{
              "options" => [%{"option" => "Continue", "weight" => 1}]
            })
        }
      }

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
               ]
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
                     "content" => "Final answer after tool execution."
                   },
                   "finish_reason" => "stop"
                 }
               ]
             }
           ])}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion,
          tool_type: "native-game-tools",
          tool_alias: "game"
        )

      Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

      {:ok, _user_message} =
        Threads.add_message_to_end(chat, :user, "Use the game tool", actor: actor)

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      message_id = context.message_id
      assert_receive {:done, ^message_id}, 2_000

      message =
        wait_for_message!(message_id, actor, fn msg ->
          msg.status == :done and length(msg.steps) == 2
        end)

      assert message_answer_text(message) == "Final answer after tool execution."
      assert "Selected option: Continue" in tool_result_texts(message)

      requests = Agent.get(agent, & &1.requests)
      assert length(Map.get(requests, "/chat/completions", [])) == 2
    end
  end

  describe "tool round limit" do
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
      assert second_request["tools"] == first_request["tools"]
      assert second_request["tool_choice"] == first_request["tool_choice"]

      assert Enum.any?(List.wrap(second_request["messages"]), fn msg ->
               msg["role"] == "tool" and msg["content"] == refusal_text and
                 msg["tool_call_id"] == "call_web_1"
             end)
    end
  end

  describe "context soft limit" do
    test "responses api keeps tools and repeats soft refusal after context soft limit" do
      first_tool_call = %{
        "id" => "fc_1",
        "type" => "function_call",
        "call_id" => "call_web_1",
        "name" => "web__read_url",
        "arguments" => Jason.encode!(%{"url" => "https://example.com"})
      }

      second_tool_call = %{
        "id" => "fc_2",
        "type" => "function_call",
        "call_id" => "call_web_2",
        "name" => "web__read_url",
        "arguments" => Jason.encode!(%{"url" => "https://example.org"})
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
                 "output" => [first_tool_call],
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
                 "id" => "resp-tool-again",
                 "object" => "response",
                 "model" => "test-responses-model",
                 "output" => [second_tool_call],
                 "usage" => %{
                   "input_tokens" => 5,
                   "output_tokens" => 2,
                   "input_tokens_details" => %{"cached_tokens" => 2},
                   "output_tokens_details" => %{"reasoning_tokens" => 1}
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
                   "input_tokens" => 6,
                   "output_tokens" => 4,
                   "input_tokens_details" => %{"cached_tokens" => 3},
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
          msg.status == :done and length(msg.steps) == 3
        end)

      assert message.status == :done
      assert message_answer_text(message) == "Final answer after context soft limit refusal."
      assert Enum.count(tool_result_texts(message), &(&1 == refusal_text)) == 2

      [first_tool_step, second_tool_step, final_step] = Enum.sort_by(message.steps, & &1.sequence)

      assert_soft_refusal_result_linked!(first_tool_step, refusal_text, handoff_available: false)

      assert_soft_refusal_result_linked!(second_tool_step, refusal_text, handoff_available: false)

      assert first_tool_step.input_tokens == 4
      assert first_tool_step.output_tokens == 3
      assert first_tool_step.cached_input_tokens == 1
      assert first_tool_step.reasoning_tokens == 2

      assert second_tool_step.input_tokens == 5
      assert second_tool_step.output_tokens == 2
      assert second_tool_step.cached_input_tokens == 2
      assert second_tool_step.reasoning_tokens == 1

      assert final_step.input_tokens == 6
      assert final_step.output_tokens == 4
      assert final_step.cached_input_tokens == 3
      assert final_step.reasoning_tokens == 3

      requests = Agent.get(agent, & &1.requests)
      responses_requests = Map.get(requests, "/responses", [])
      assert length(responses_requests) == 3

      [first_request, second_request, final_request] = responses_requests
      assert is_list(first_request["tools"])
      assert second_request["tools"] == first_request["tools"]
      assert final_request["tools"] == first_request["tools"]

      assert Enum.any?(List.wrap(second_request["input"]), fn item ->
               item["type"] == "function_call_output" and item["call_id"] == "call_web_1" and
                 item["output"] == refusal_text
             end)

      assert Enum.any?(List.wrap(final_request["input"]), fn item ->
               item["type"] == "function_call_output" and item["call_id"] == "call_web_2" and
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
          "Non-handoff tool calls will be refused. " <>
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
      assert second_request["tools"] == first_request["tools"]

      assert Enum.any?(List.wrap(second_request["input"]), fn item ->
               item["type"] == "function_call_output" and item["call_id"] == "call_web_1" and
                 item["output"] == refusal_text
             end)

      refute Enum.any?(List.wrap(second_request["input"]), fn item ->
               item["type"] == "function_call_output" and
                 String.contains?(to_string(item["output"] || ""), old_final_instruction)
             end)
    end

    test "linked fork context soft limit does not offer a handoff rejected by subchat policy" do
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
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3}
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
                       %{"type" => "output_text", "text" => "Final answer.", "annotations" => []}
                     ]
                   }
                 ],
                 "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
               }
             }
           ])}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, agent} = start_scripted_server!(scripts)

      root =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!()

      chat =
        create_chat_with_tool!(actor, base_url, :responses,
          max_tool_rounds: 5,
          context_length: 10,
          context_soft_limit_percent: 50,
          handoff_tool?: true,
          chat_attrs: %{parent_chat_id: root.id, parent_relation_kind: :fork, subagent: true}
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

      assert refusal_text in tool_result_texts(message)

      [tool_step, _final_step] = Enum.sort_by(message.steps, & &1.sequence)
      assert_soft_refusal_result_linked!(tool_step, refusal_text, handoff_available: false)

      [first_request, _second_request] =
        Agent.get(agent, & &1.requests) |> Map.fetch!("/responses")

      assert "agent_management__handoff" in request_tool_names(first_request)
    end
  end

  describe "handoff" do
    test "handoff tool finalizes parent message with the tool step only" do
      handoff_summary = "Continue from the handoff tool summary."

      handoff_call = %{
        "id" => "call_handoff_1",
        "type" => "function",
        "function" => %{
          "name" => "agent_management__handoff",
          "arguments" => Jason.encode!(%{"summary" => handoff_summary})
        }
      }

      scripts = %{
        "/chat/completions" => [
          {200,
           sse_chunks([
             %{
               "id" => "chatcmpl-handoff-tool",
               "object" => "chat.completion",
               "created" => 1,
               "model" => "test-chat-model",
               "choices" => [
                 %{
                   "index" => 0,
                   "message" => %{
                     "role" => "assistant",
                     "content" => "",
                     "tool_calls" => [handoff_call]
                   },
                   "finish_reason" => "tool_calls"
                 }
               ]
             }
           ])},
          {200,
           sse_chunks([
             %{
               "id" => "chatcmpl-child",
               "object" => "chat.completion",
               "created" => 2,
               "model" => "test-chat-model",
               "choices" => [
                 %{
                   "index" => 0,
                   "message" => %{
                     "role" => "assistant",
                     "content" => "Child generation started."
                   },
                   "finish_reason" => "stop"
                 }
               ]
             }
           ])}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, handoff_tool?: true)

      Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

      {:ok, _user_message} =
        Threads.add_message_to_end(chat, :user, "Hand off this work", actor: actor)

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      message_id = context.message_id
      assert_receive {:done, ^message_id}, 2_000

      message =
        wait_for_message!(message_id, actor, fn msg ->
          msg.status == :done and length(msg.steps) == 1
        end)

      assert message_answer_text(message) == ""

      [step] = Enum.sort_by(message.steps, & &1.sequence)
      assert step.status == :done
      assert Enum.count(step.items || [], &(&1.type == :tool_call)) == 1
      assert Enum.count(step.items || [], &(&1.type == :tool_result)) == 1
      refute Enum.any?(step.items || [], &(&1.type == :answer))

      [handoff_payload] = handoff_payloads(message)
      target_id = handoff_payload["chat_id"]
      child_generation_message_id = handoff_payload["generation_message_id"]
      assert is_integer(target_id)
      assert is_integer(child_generation_message_id)

      target =
        Chat
        |> Ash.get!(target_id, actor: actor, load: [:last_message])

      assert target.parent_chat_id == chat.id
      assert target.parent_message_id == message_id
      assert target.parent_relation_kind == Handoff.relation_kind()

      child_messages = messages_for_chat!(actor, target_id)
      assert hd(child_messages).role == :user
      assert message_answer_text(hd(child_messages)) == ""

      assert hd(child_messages).steps
             |> Enum.flat_map(& &1.items)
             |> Enum.sort_by(& &1.sequence)
             |> Enum.map(& &1.type) == [:handoff_history, :handoff_message]

      child_prompt = user_message_text(hd(child_messages))
      assert String.starts_with?(child_prompt, "History")
      assert String.contains?(child_prompt, "Hand off this work")
      assert String.contains?(child_prompt, "Handoff message")
      assert String.contains?(child_prompt, handoff_summary)

      assert wait_for_message!(child_generation_message_id, actor, &(&1.status == :done)).status ==
               :done

      requests = Agent.get(agent, & &1.requests)
      assert length(Map.get(requests, "/chat/completions", [])) == 2
    end

    test "handoff transfers an active background task to the child generation" do
      test_pid = self()

      handoff_call = %{
        "id" => "call_handoff_with_background_task",
        "type" => "function",
        "function" => %{
          "name" => "agent_management__handoff",
          "arguments" =>
            Jason.encode!(%{
              "summary" => "Background task 00000000-0000-0000-0000-000000000000 is still queued."
            })
        }
      }

      parent_chunks =
        sse_chunks([
          %{
            "id" => "chatcmpl-handoff-background-parent",
            "object" => "chat.completion",
            "created" => 1,
            "model" => "test-chat-model",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => "",
                  "tool_calls" => [handoff_call]
                },
                "finish_reason" => "tool_calls"
              }
            ]
          }
        ])

      child_chunks =
        sse_chunks([
          %{
            "id" => "chatcmpl-handoff-background-child",
            "object" => "chat.completion",
            "created" => 2,
            "model" => "test-chat-model",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "Child finished."},
                "finish_reason" => "stop"
              }
            ]
          }
        ])

      scripts = %{
        "/chat/completions" => [
          {200,
           fn ->
             send(test_pid, {:provider_waiting, :parent, self()})

             receive do
               :release_provider -> parent_chunks
             after
               5_000 -> parent_chunks
             end
           end},
          {200,
           fn ->
             send(test_pid, {:provider_waiting, :child, self()})

             receive do
               :release_provider -> child_chunks
             after
               5_000 -> child_chunks
             end
           end}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, _agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, handoff_tool?: true)

      {:ok, _user_message} =
        Threads.add_message_to_end(chat, :user, "Keep the task alive through handoff",
          actor: actor
        )

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      assert_receive {:provider_waiting, :parent, parent_provider}, 2_000

      task =
        create!(
          BackgroundTask,
          :create,
          %{
            kind: "fork",
            adapter: "fork",
            status: :queued,
            function_name: "fork",
            arguments: %{"task" => "Long-running work"},
            execution_context: %{
              "owner_id" => actor.id,
              "chat_id" => chat.id,
              "message_id" => context.message_id,
              "assistant_message_id" => context.message_id
            },
            runner_ref: %{},
            source_chat_id: chat.id,
            source_message_id: context.message_id,
            lifecycle_message_id: context.message_id
          },
          actor
        )

      send(parent_provider, :release_provider)
      assert_receive {:provider_waiting, :child, child_provider}, 2_000

      parent = wait_for_message!(context.message_id, actor, &(&1.status == :done))
      [handoff_payload] = handoff_payloads(parent)
      child_message_id = handoff_payload["generation_message_id"]

      transferred = Ash.get!(BackgroundTask, task.id, actor: actor)
      assert transferred.status == :queued
      assert transferred.cancel_requested == false
      assert transferred.lifecycle_message_id == child_message_id
      assert transferred.source_chat_id == chat.id
      assert transferred.source_message_id == context.message_id
      assert transferred.execution_context == task.execution_context

      send(child_provider, :release_provider)
      assert wait_for_message!(child_message_id, actor, &(&1.status == :done)).status == :done

      canceled =
        wait_for_background_task!(task.id, actor, fn current ->
          current.cancel_requested == true
        end)

      assert canceled.lifecycle_message_id == child_message_id
    end

    test "handoff executes alone and soft-refuses other calls in the same response" do
      background_call = %{
        "id" => "call_background_with_handoff",
        "type" => "function",
        "function" => %{
          "name" => "agent_management__fork_background",
          "arguments" => Jason.encode!(%{"task" => "This call must not start."})
        }
      }

      handoff_call = %{
        "id" => "call_single_handoff",
        "type" => "function",
        "function" => %{
          "name" => "agent_management__handoff",
          "arguments" => Jason.encode!(%{"summary" => "Continue without starting the task."})
        }
      }

      scripts = %{
        "/chat/completions" => [
          {200,
           sse_chunks([
             %{
               "id" => "chatcmpl-mixed-handoff",
               "object" => "chat.completion",
               "created" => 1,
               "model" => "test-chat-model",
               "choices" => [
                 %{
                   "index" => 0,
                   "message" => %{
                     "role" => "assistant",
                     "content" => "",
                     "tool_calls" => [background_call, handoff_call]
                   },
                   "finish_reason" => "tool_calls"
                 }
               ]
             }
           ])},
          {200,
           sse_chunks([
             %{
               "id" => "chatcmpl-mixed-handoff-child",
               "object" => "chat.completion",
               "created" => 2,
               "model" => "test-chat-model",
               "choices" => [
                 %{
                   "index" => 0,
                   "message" => %{"role" => "assistant", "content" => "Continued."},
                   "finish_reason" => "stop"
                 }
               ]
             }
           ])}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, _agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, handoff_tool?: true)

      {:ok, _user_message} =
        Threads.add_message_to_end(chat, :user, "Hand off without starting another task",
          actor: actor
        )

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      message = wait_for_message!(context.message_id, actor, &(&1.status == :done))

      assert length(handoff_payloads(message)) == 1

      assert message
             |> tool_result_raw_errors()
             |> Enum.member?("handoff_must_be_called_alone")

      background_tasks =
        BackgroundTask
        |> Ash.Query.filter(source_message_id == ^context.message_id)
        |> Ash.read!(authorize?: false)

      assert background_tasks == []

      [handoff_payload] = handoff_payloads(message)

      assert wait_for_message!(
               handoff_payload["generation_message_id"],
               actor,
               &(&1.status == :done)
             ).status == :done
    end
  end

  # A chat with an agent-mode bot bound to one tool (and optionally the
  # agent-management handoff tool), configured for `provider_type` at `base_url`.
  defp create_chat_with_tool!(actor, base_url, provider_type, opts) do
    configuration =
      create_configuration!(actor, %{
        model_name: "test-model",
        timeout_seconds: 5,
        context_length: Keyword.get(opts, :context_length),
        provider_attrs: %{type: provider_type, base_url: base_url}
      })

    bot =
      create_bot!(actor, %{
        max_tool_rounds: Keyword.get(opts, :max_tool_rounds, 20),
        context_soft_limit_percent: Keyword.get(opts, :context_soft_limit_percent, 80),
        history_mode: :agent
      })

    tool_alias = Keyword.get(opts, :tool_alias, "web")

    tool =
      create_tool_instance!(actor, %{
        type: Keyword.get(opts, :tool_type, "native-web-reader"),
        name: "Test tool",
        alias: tool_alias,
        description: "",
        max_output_tokens: 20_000
      })

    create_bot_tool_binding!(actor, bot, tool, %{alias: tool_alias})

    if Keyword.get(opts, :handoff_tool?, false) do
      handoff =
        create_tool_instance!(actor, %{type: "native-agent-management", max_output_tokens: 20_000})

      create_bot_tool_binding!(actor, bot, handoff, %{alias: "agent_management", sequence: 1})
    end

    create_chat!(
      actor,
      Map.merge(
        %{bot_id: bot.id, llm_configuration_id: configuration.id},
        Keyword.get(opts, :chat_attrs, %{})
      )
    )
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

    if message.status in [:done, :error, :canceled],
      do: wait_for_generation_worker_to_stop!(message_id)

    message
  end

  defp wait_for_background_task!(task_id, actor, predicate, timeout_ms \\ 2_000)
       when is_function(predicate, 1) do
    wait_until(
      fn ->
        task = Ash.get!(BackgroundTask, task_id, actor: actor)
        predicate.(task) && task
      end,
      timeout: timeout_ms,
      interval: 20
    )
  end

  defp user_message_text(message) do
    History.project_user_input_text(message)
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

  defp handoff_payloads(message) do
    message
    |> Map.get(:steps, [])
    |> Enum.flat_map(&Map.get(&1, :items, []))
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&Map.get(&1, :contents, []))
    |> Enum.filter(&(&1.kind == :opaque))
    |> Enum.flat_map(fn content ->
      case get_in(content.content_json || %{}, ["raw", "handoff"]) do
        %{} = payload -> [payload]
        _other -> []
      end
    end)
  end

  defp tool_result_raw_errors(message) do
    message
    |> Map.get(:steps, [])
    |> Enum.flat_map(&Map.get(&1, :items, []))
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&Map.get(&1, :contents, []))
    |> Enum.filter(&(&1.kind == :opaque))
    |> Enum.map(&get_in(&1.content_json || %{}, ["raw", "error"]))
    |> Enum.reject(&is_nil/1)
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
