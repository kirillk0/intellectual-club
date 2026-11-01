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
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.Tools.Drivers.NativeArtifactReader
  alias IntellectualClub.Tools.ExecutionContext
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
    for boundary <- [:continue, :retry_refusal, :resume_after_refusal, :lost_followup_ack] do
      @tag :tmp_dir
      @tag refusal_boundary: boundary
      test "a preparation refusal preserves the original request across #{boundary}",
           %{refusal_boundary: boundary, tmp_dir: storage} do
        alias IntellectualClub.Chat.{ForkHistoryCorruptFixture, Handoff}
        alias IntellectualClub.Files.File, as: StoredFile
        alias IntellectualClub.Generation.Persistence
        alias IntellectualClub.Test.GenerationRuntime, as: Runtime
        alias IntellectualClub.Test.GenerationRuntime.{Barrier, CompactionAdapter}

        put_app_env(:file_storage_path, storage)
        %{user: actor} = user_fixture()
        tool = create_tool_instance!(actor, type: "native-agent-management")
        summary = "Attempted checkpoint"

        request = %{
          "model" => "test-model",
          "messages" => [
            %{"role" => "system", "content" => "Pinned system instruction"},
            %{"role" => "user", "content" => "Original request history"}
          ],
          "tools" => [
            %{
              "type" => "function",
              "function" => %{
                "name" => "agent_management__handoff",
                "parameters" => %{"type" => "object"}
              }
            }
          ],
          "temperature" => 0.25,
          "tool_choice" => "auto",
          "stream" => true
        }

        snapshot = CompactionAdapter.request_snapshot(request)

        fixture =
          Runtime.generation_fixture!(
            actor: actor,
            request: request,
            context: %{
              adapter_module: CompactionAdapter,
              model_name: "test-model",
              messages: snapshot.model_input,
              tools_payload: request["tools"],
              tool_instances_by_alias: %{"agent_management" => tool},
              test_tool_name: "agent_management__handoff",
              test_tool_args: %{"summary" => summary},
              test_compaction_followup_barrier?: true
            }
          )

        files_before =
          Ash.read!(StoredFile, authorize?: false) |> Enum.map(& &1.id) |> Enum.sort()

        gate = Barrier.gate_persistence(fixture.message.id, tool_followup: :start)
        gen = Runtime.start_generation!(fixture)
        pinned_message = Runtime.message!(fixture)
        selected = create_configuration!(actor, model_name: "next-message-model")

        fixture.chat
        |> Ash.Changeset.for_update(:update, %{llm_configuration_id: selected.id}, actor: actor)
        |> Ash.update!(actor: actor)

        send(gen.provider, {:complete, :tools})
        writer = Barrier.await_persistence(:tool_followup, :start)
        [original_result] = Runtime.items!(fixture, :tool_result)

        assert compaction_payloads(Runtime.message!(fixture, steps: [items: [:contents]])) == [
                 %{"summary" => summary}
               ]

        # A legacy fork with a missing anchor refuses canonical history reads,
        # but must not invalidate the request already pinned for this generation.
        corrupt = Ash.get!(ForkHistoryCorruptFixture, fixture.chat.id, actor: actor)

        corrupt
        |> Ash.Changeset.for_update(:corrupt_anchor, %{fork_task: "Missing legacy anchor"},
          actor: actor
        )
        |> Ash.update!(actor: actor)

        assert {:error, :fork_context_unavailable} =
                 Handoff.prepare_compaction(fixture.message.id, actor, summary)

        steer = Runtime.enqueue_steer!(fixture, "Keep this steering")

        assert {:ok, follow_up} =
                 QueuedMessages.enqueue_follow_up(
                   fixture.chat.id,
                   %{content: "Keep this queued follow-up"},
                   actor
                 )

        transient_failure =
          if boundary == :retry_refusal do
            Runtime.inject_sql_failure!(
              "chat_message_contents",
              "BEFORE INSERT",
              "NEW.kind = 'opaque' AND " <>
                "NEW.content_json #>> '{raw,error}' = 'compaction_preparation_failed'",
              "40001",
              1
            )
          end

        Barrier.detach(gate)
        Barrier.release(writer)
        assert_receive {:compaction_followup, preparing, followup_opts}, 5_000
        if transient_failure, do: assert(Runtime.sql_attempts(transient_failure) == 2)
        [refused] = followup_opts.results
        assert refused.item_id == original_result.id

        assert refused.result_raw == %{
                 "error" => "compaction_preparation_failed",
                 "reason" => "fork_context_unavailable"
               }

        assert refused.text =~ "[tool error]"
        assert refused.responses_item["output"] == refused.text
        assert followup_opts.runtime_step.raw_request == request
        assert Runtime.items!(fixture, :handoff_history) == []
        assert Runtime.items!(fixture, :handoff_message) == []
        assert length(Runtime.steps!(fixture)) == 1
        assert {:ok, %{status: :pending}} = QueuedMessages.get(steer.id, actor)

        {worker, preparing} =
          if boundary == :resume_after_refusal do
            monitor = Process.monitor(preparing)
            :ok = GenServer.stop(gen.worker, :normal)
            assert_receive {:DOWN, ^monitor, :process, ^preparing, _reason}, 5_000
            assert Runtime.message!(fixture).status == :generating

            worker = Runtime.start_worker!(fixture, initial_resume_mode: :completed_tool_step)
            assert_receive {:compaction_followup, resumed, resumed_opts}, 5_000
            assert resumed_opts.results == followup_opts.results
            assert resumed_opts.runtime_step.raw_request == request
            {worker, resumed}
          else
            {gen.worker, preparing}
          end

        acknowledgement_gate =
          if boundary == :lost_followup_ack,
            do: Barrier.gate_persistence(fixture.message.id, tool_followup: :stop)

        send(preparing, :build_followup)
        assert_receive {:compaction_injection, injecting, _request, [_steer], _context}, 5_000
        send(injecting, :inject_steering)

        if acknowledgement_gate do
          committed = Barrier.await_persistence(:tool_followup, :stop)
          Barrier.detach(acknowledgement_gate)
          Barrier.crash(committed)
        end

        {provider, continued} = Runtime.await_provider!(fixture)
        assert Map.drop(continued, ["messages"]) == Map.drop(request, ["messages"])
        assert Enum.take(continued["messages"], 2) == request["messages"]

        assert [%{"tool_call_id" => "call_async", "content" => error_text}] =
                 Enum.filter(continued["messages"], &(&1["role"] == "tool"))

        assert error_text == refused.text
        refute Jason.encode!(continued) =~ "Context compaction requested"
        assert Jason.encode!(continued) =~ "Keep this steering"
        refute Jason.encode!(continued) =~ "Keep this queued follow-up"

        state = :sys.get_state(worker)
        assert state.tool_round == 1
        assert state.refusal_round == 0
        message = Runtime.message!(fixture, steps: [items: [:contents]])
        assert message.status == :generating
        assert message.parent_id == fixture.message.parent_id
        assert message.llm_configuration_id == pinned_message.llm_configuration_id
        assert message.chat_id == fixture.chat.id
        assert compaction_payloads(message) == []
        [source, receiving] = Enum.sort_by(message.steps, & &1.sequence)
        assert source.status == :done
        assert receiving.status == :waiting_provider
        assert checkpoint_items(source) == []
        assert StepRequests.request_for_step!(receiving.id, actor: actor) == continued
        [result] = Runtime.items!(fixture, :tool_result)
        [call] = Runtime.items!(fixture, :tool_call)
        assert result.id == original_result.id
        assert result.tool_call_item_id == call.id
        assert result.sequence == original_result.sequence
        assert item_text(result) == refused.text
        assert Persistence.load_step_for_followup!(source.id).results == [refused]
        assert Runtime.items!(fixture, :error) == []
        [steering] = Runtime.items!(fixture, :steering)
        assert steering.chat_message_step_id == receiving.id

        assert {:ok, %{status: :delivered, steering_item_id: steering_id}} =
                 QueuedMessages.get(steer.id, actor)

        assert steering_id == steering.id
        assert {:ok, pending} = QueuedMessages.get(follow_up.id, actor)
        assert pending.status == :pending
        assert pending.anchor_message_id == fixture.message.id
        assert pending.assistant_message_id == nil

        assert files_before ==
                 Ash.read!(StoredFile, authorize?: false) |> Enum.map(& &1.id) |> Enum.sort()

        assert Path.wildcard(Path.join(storage, "**/*")) == []
        assert_no_handoff_child!(fixture.chat.id, actor)
        assert Ash.get!(Chat, fixture.chat.id, actor: actor).llm_configuration_id == selected.id

        # Repair only the test corruption and cancel the preserved test follow-up
        # before completion, so no queued generation outlives this sandbox.
        corrupt
        |> Ash.Changeset.for_update(:corrupt_anchor, %{fork_task: nil}, actor: actor)
        |> Ash.update!(actor: actor)

        assert {:ok, %{status: :canceled}} = QueuedMessages.cancel(follow_up.id, actor)
        send(provider, {:complete, :answer})
        Runtime.assert_worker_stopped!(worker)
        assert Runtime.message!(fixture).status == :done
        assert Runtime.answers!(fixture) == ["Committed answer"]
      end
    end

    test "a database failure saving the preparation refusal is not a soft tool error" do
      alias IntellectualClub.Chat.ForkHistoryCorruptFixture
      alias IntellectualClub.Test.GenerationRuntime, as: Runtime
      alias IntellectualClub.Test.GenerationRuntime.Barrier

      %{user: actor} = user_fixture()
      tool = create_tool_instance!(actor, type: "native-agent-management")

      fixture =
        Runtime.generation_fixture!(
          actor: actor,
          context: %{
            tool_instances_by_alias: %{"agent_management" => tool},
            test_tool_name: "agent_management__handoff",
            test_tool_args: %{"summary" => "Checkpoint"}
          }
        )

      gate = Barrier.gate_persistence(fixture.message.id, tool_followup: :start)
      gen = Runtime.start_generation!(fixture)
      send(gen.provider, {:complete, :tools})
      writer = Barrier.await_persistence(:tool_followup, :start)
      [original] = Runtime.items!(fixture, :tool_result)

      Ash.get!(ForkHistoryCorruptFixture, fixture.chat.id, actor: actor)
      |> Ash.Changeset.for_update(:corrupt_anchor, %{fork_task: "Missing legacy anchor"},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      failure =
        Runtime.inject_sql_failure!(
          "chat_message_contents",
          "BEFORE INSERT",
          "NEW.kind = 'opaque' AND " <>
            "NEW.content_json #>> '{raw,error}' = 'compaction_preparation_failed'",
          "23514"
        )

      Barrier.detach(gate)
      Barrier.release(writer)
      monitor = gen.monitor
      worker = gen.worker
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
      assert Runtime.sql_attempts(failure) == 1
      failed = Runtime.message!(fixture)
      assert failed.status == :error
      assert failed.error_detail == "Generation tool_followup failed: Postgrex.Error"
      assert Runtime.step!(fixture).status == :error
      Runtime.refute_provider_started(fixture)
      Runtime.refute_followup_prepared(fixture)
      assert length(Runtime.steps!(fixture)) == 1
      [unchanged] = Runtime.items!(fixture, :tool_result)
      assert unchanged.id == original.id

      assert Enum.sort_by(unchanged.contents, & &1.sequence) ==
               Enum.sort_by(original.contents, & &1.sequence)

      assert Runtime.items!(fixture, :handoff_history) == []
      assert Runtime.items!(fixture, :handoff_message) == []
    end

    test "compaction keeps the message and pinned configuration alive with an accessible archive" do
      summary = "Continue from this checkpoint summary."

      handoff =
        chat_tool_call("call_handoff_1", "agent_management__handoff", %{"summary" => summary})

      scripts = %{
        "/chat/completions" => [
          {200,
           blocked_chunks(:before_compaction, chat_chunks([handoff], "Original partial answer."))},
          {200, blocked_chunks(:after_compaction, chat_chunks([], "Continued answer."))}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, handoff_tool?: true)

      Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

      {:ok, user_message} =
        Threads.add_message_to_end(chat, :user, "Hand off this work", actor: actor)

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      message_id = context.message_id
      assert_receive {:provider_waiting, :before_compaction, before_provider}, 2_000
      before = Ash.get!(ChatMessage, message_id, actor: actor)

      [{worker, _}] =
        Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id})

      monitor = Process.monitor(worker)

      selected = create_configuration!(actor, model_name: "next-message-model")

      chat
      |> Ash.Changeset.for_update(:update, %{llm_configuration_id: selected.id}, actor: actor)
      |> Ash.update!(actor: actor)

      send(before_provider, :release_provider)
      assert_receive {:provider_waiting, :after_compaction, after_provider}, 2_000

      message =
        Ash.get!(ChatMessage, message_id, actor: actor, load: [steps: [items: [:contents]]])

      assert message.status == :generating
      assert message.finished_at == nil
      assert message.chat_id == chat.id
      assert message.parent_id == user_message.id
      assert message.llm_configuration_id == before.llm_configuration_id
      assert message.generation_fence_token == before.generation_fence_token

      assert [{^worker, _}] =
               Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id})

      refute_received {:done, ^message_id}
      refute_received {:DOWN, ^monitor, :process, ^worker, _}
      assert compaction_payloads(message) == [%{"summary" => summary}]
      assert_no_handoff_child!(chat.id, actor)

      [source_step, next_step] = Enum.sort_by(message.steps, & &1.sequence)
      assert source_step.status == :done
      assert next_step.status == :waiting_provider
      assert next_step.request_mode == :full
      assert next_step.request_base_sequence == nil
      assert next_step.request_checkpoint_distance == 0
      [history, checkpoint] = checkpoint_items(source_step)
      assert checkpoint.sequence == history.sequence + 1
      assert checkpoint |> item_text() == summary
      [archive] = Enum.filter(history.contents, &(&1.kind == :media))
      assert {:ok, {file, archive_text}} = Files.load_payload(archive.file_id)
      assert file.filename == "full_conversation.md"
      assert archive_text =~ "Hand off this work"
      assert archive_text =~ "Original partial answer."

      reader = create_tool_instance!(actor, type: "native-artifact-reader")

      assert {:ok, {read_text, read_raw}} =
               NativeArtifactReader.execute(
                 reader,
                 "read_file",
                 %{"file_id" => file.external_id},
                 %ExecutionContext{
                   owner_id: actor.id,
                   chat_id: chat.id,
                   message_id: message_id,
                   assistant_message_id: message_id
                 }
               )

      assert read_text =~ "Original partial answer."
      assert read_raw["file_id"] == file.external_id

      [initial, continued] = scripted_requests(agent, "/chat/completions")
      assert initial["model"] == continued["model"]
      assert continued["model"] == "test-model"
      assert initial["tools"] == continued["tools"]

      assert Enum.filter(initial["messages"], &(&1["role"] == "system")) ==
               Enum.filter(continued["messages"], &(&1["role"] == "system"))

      assert Jason.encode!(continued["messages"]) =~ summary
      assert Jason.encode!(continued["messages"]) =~ file.external_id

      refute Enum.any?(
               continued["messages"],
               &(&1["role"] == "tool" or Map.has_key?(&1, "tool_calls"))
             )

      refute Jason.encode!(continued["messages"]) =~ "call_handoff_1"

      assert StepRequests.request_for_step!(next_step.id, actor: actor)["messages"] ==
               continued["messages"]

      assert Ash.get!(Chat, chat.id, actor: actor).llm_configuration_id == selected.id
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == message_id

      send(after_provider, :release_provider)
      assert_receive {:done, ^message_id}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
      message = wait_for_message!(message_id, actor, &(&1.status == :done))
      assert message_answer_text(message) =~ "Continued answer."
      assert length(message.steps) == 2

      assert Enum.map(messages_for_chat!(actor, chat.id), & &1.id) == [
               user_message.id,
               message_id
             ]
    end

    test "compaction preserves an active background task until the same message finishes" do
      handoff =
        chat_tool_call("call_handoff_with_background_task", "agent_management__handoff", %{
          "summary" => "The background task is still queued."
        })

      scripts = %{
        "/chat/completions" => [
          {200, blocked_chunks(:before_compaction, chat_chunks([handoff]))},
          {200, blocked_chunks(:after_compaction, chat_chunks([], "Finished after compaction."))}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, _agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, handoff_tool?: true)

      {:ok, _user_message} =
        Threads.add_message_to_end(chat, :user, "Keep the task alive through compaction",
          actor: actor
        )

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      assert_receive {:provider_waiting, :before_compaction, before_provider}, 2_000

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

      send(before_provider, :release_provider)
      assert_receive {:provider_waiting, :after_compaction, after_provider}, 2_000
      assert Ash.get!(ChatMessage, context.message_id, actor: actor).status == :generating
      retained = Ash.get!(BackgroundTask, task.id, actor: actor)
      assert retained.status == :queued
      assert retained.cancel_requested == false
      assert retained.lifecycle_message_id == context.message_id
      assert retained.source_chat_id == chat.id
      assert retained.source_message_id == context.message_id
      assert retained.execution_context == task.execution_context
      assert_no_handoff_child!(chat.id, actor)

      send(after_provider, :release_provider)
      assert wait_for_message!(context.message_id, actor, &(&1.status == :done)).status == :done
      canceled = wait_for_background_task!(task.id, actor, &(&1.status == :canceled))
      assert canceled.lifecycle_message_id == context.message_id
      assert canceled.source_message_id == context.message_id
    end

    test "handoff executes alone and soft-refuses other calls in the same response" do
      background_call =
        chat_tool_call("call_background_with_handoff", "agent_management__fork_background", %{
          "task" => "Must not start"
        })

      handoff_call =
        chat_tool_call("call_single_handoff", "agent_management__handoff", %{
          "summary" => "Continue after the single handoff."
        })

      scripts = %{
        "/chat/completions" => [
          {200, chat_chunks([background_call, handoff_call])},
          {200, chat_chunks([], "Continued without creating a child.")}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, handoff_tool?: true)

      {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "Compact only", actor: actor)

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      message = wait_for_message!(context.message_id, actor, &(&1.status == :done))

      assert compaction_payloads(message) == [
               %{"summary" => "Continue after the single handoff."}
             ]

      assert "handoff_must_be_called_alone" in tool_result_raw_errors(message)

      assert [] ==
               BackgroundTask
               |> Ash.Query.filter(source_message_id == ^context.message_id)
               |> Ash.read!(actor: actor)

      assert_no_handoff_child!(chat.id, actor)
      assert message_answer_text(message) == "Continued without creating a child."
      assert length(scripted_requests(agent, "/chat/completions")) == 2
    end

    test "repeated compaction refreshes Responses input and resets tool and refusal limits" do
      scripts =
        for round <- 1..2,
            script <- [
              {200,
               responses_chunks("work_#{round}", [
                 response_message("Original work #{round}."),
                 response_tool_call("game_#{round}", "game__random_select", %{
                   "options" => [%{"option" => "executed_#{round}", "weight" => 1}]
                 })
               ])},
              {200,
               responses_chunks(
                 "refused_#{round}_1",
                 [
                   response_tool_call("refused_#{round}_1", "game__random_select", %{
                     "options" => [%{"option" => "must_not_run", "weight" => 1}]
                   })
                 ],
                 true
               )},
              {200,
               responses_chunks(
                 "refused_#{round}_2",
                 [
                   response_tool_call("refused_#{round}_2", "game__random_select", %{
                     "options" => [%{"option" => "must_not_run", "weight" => 1}]
                   })
                 ],
                 true
               )},
              {200,
               responses_chunks(
                 "compact_#{round}",
                 [
                   response_tool_call("handoff_#{round}", "agent_management__handoff", %{
                     "summary" => "Checkpoint summary #{round}."
                   })
                 ],
                 true
               )}
            ],
            do: script

      scripts = %{
        "/responses" =>
          scripts ++
            [{200, responses_chunks("final", [response_message("Finished both checkpoints.")])}]
      }

      %{user: actor} = user_fixture()
      {base_url, agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :responses,
          handoff_tool?: true,
          tool_type: "native-game-tools",
          tool_alias: "game",
          max_tool_rounds: 1,
          context_length: 10,
          context_soft_limit_percent: 50
        )

      {:ok, _user_message} =
        Threads.add_message_to_end(chat, :user, "Original user instruction", actor: actor)

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      message =
        wait_for_message!(context.message_id, actor, &(&1.status in [:done, :error]), 5_000)

      assert message.status == :done
      assert message_answer_text(message) =~ "Finished both checkpoints."

      assert compaction_payloads(message) == [
               %{"summary" => "Checkpoint summary 1."},
               %{"summary" => "Checkpoint summary 2."}
             ]

      assert Enum.count(tool_result_raw_errors(message), &(&1 == "context_limit_reached")) == 4
      refute "tool_call_limit_reached" in tool_result_raw_errors(message)

      for round <- 1..2,
          do:
            assert(
              Enum.any?(tool_result_texts(message), &String.contains?(&1, "executed_#{round}"))
            )

      assert_no_handoff_child!(chat.id, actor)

      steps = Enum.sort_by(message.steps, & &1.sequence)
      assert Enum.map(steps, & &1.sequence) == Enum.to_list(1..9)
      requests = scripted_requests(agent, "/responses")
      assert length(requests) == 9

      for {step_index, summary} <- [{4, "Checkpoint summary 1."}, {8, "Checkpoint summary 2."}] do
        request = Enum.at(requests, step_index)
        assert Jason.encode!(request["input"]) =~ summary
        refute Map.has_key?(request, "previous_response_id")

        refute Enum.any?(
                 request["input"],
                 &(&1["type"] in ["function_call", "function_call_output"])
               )

        assert request["tools"] == hd(requests)["tools"]
        assert Enum.at(steps, step_index).request_mode == :full
      end

      [first_history, _] = checkpoint_items(Enum.at(steps, 3))
      [second_history, _] = checkpoint_items(Enum.at(steps, 7))
      [first_archive] = Enum.filter(first_history.contents, &(&1.kind == :media))
      [second_archive] = Enum.filter(second_history.contents, &(&1.kind == :media))
      assert first_archive.file_id != second_archive.file_id
      assert {:ok, {_file, archive}} = Files.load_payload(second_archive.file_id)
      assert length(Regex.scan(~r/Original user instruction/, archive)) == 1
      assert length(Regex.scan(~r/Original work 1\./, archive)) == 1
      assert length(Regex.scan(~r/Original work 2\./, archive)) == 1
      refute archive =~ "Checkpoint summary 1."
      refute archive =~ "full_conversation.md"
    end

    @tag :whitebox
    test "queue snapshot retries reuse one rolloff and inject against the compacted request context" do
      alias IntellectualClub.Chat.Handoff
      alias IntellectualClub.Generation.CacheControl
      alias IntellectualClub.Test.GenerationRuntime, as: Runtime
      alias IntellectualClub.Test.GenerationRuntime.{Barrier, CompactionAdapter}

      %{user: actor} = user_fixture()

      tool = create_tool_instance!(actor, type: "native-agent-management")

      request = %{
        "model" => "test-model",
        "messages" =>
          for(index <- 1..12, do: %{"role" => "user", "content" => "Old request #{index}"})
          |> CacheControl.apply_history_end_marker(history_length: 12)
      }

      fixture =
        Runtime.generation_fixture!(
          actor: actor,
          request: request,
          context: %{
            adapter_module: CompactionAdapter,
            model_name: "test-model",
            cache_control_enabled: true,
            history_length: 12,
            messages: request["messages"],
            tool_instances_by_alias: %{"agent_management" => tool},
            test_tool_name: "agent_management__handoff",
            test_tool_args: %{"summary" => "Checkpoint"}
          }
        )

      gate = Barrier.gate_persistence(fixture.message.id, tool_followup: :start)
      gen = Runtime.start_generation!(fixture)
      send(gen.provider, {:complete, :tools})
      writer = Barrier.await_persistence(:tool_followup, :start)
      {:ok, queued} = QueuedMessages.enqueue_steer(fixture.message.id, "Old queued steer", actor)
      mfa = {Handoff, :prepare_compaction, 3}
      :erlang.trace_pattern(mfa, true, [:local])
      :erlang.trace(writer.pid, true, [:call, :arity])
      on_exit(fn -> :erlang.trace_pattern(mfa, false, [:local]) end)
      Barrier.detach(gate)
      Barrier.release(writer)

      for attempt <- 0..8 do
        assert_receive {:compaction_injection, injecting, initial, [item], injection_context},
                       5_000

        assert item.text == "Old queued steer"
        snapshot = CompactionAdapter.request_snapshot(initial)
        assert injection_context.messages == snapshot.model_input
        assert injection_context.history_length == snapshot.history_length
        assert injection_context.history_length < 12
        assert injection_context.request_payload == initial

        if attempt < 8 do
          # The edit invalidates this snapshot. It rolls back with the failed
          # publication because this test uses one shared sandbox transaction.
          send(
            injecting,
            {:inject_steering,
             fn ->
               {:ok, _edited} =
                 QueuedMessages.update(queued.id, %{content: "Changed during publication"}, actor)
             end}
          )
        else
          send(injecting, :inject_steering)
        end
      end

      {provider, request} = Runtime.await_provider!(fixture)
      delivery = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivery}
      assert_received {:trace, _, :call, ^mfa}
      refute_received {:trace, _, :call, ^mfa}
      :erlang.trace_pattern(mfa, false, [:local])
      assert Jason.encode!(request) =~ "Old queued steer"
      refute Jason.encode!(request) =~ "Changed during publication"
      assert length(Runtime.items!(fixture, :handoff_message)) == 1
      assert length(Runtime.items!(fixture, :steering)) == 1
      assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, actor)
      send(provider, {:complete, :answer})
      Runtime.assert_worker_stopped!(gen.worker)
    end

    test "a lost compaction acknowledgement preserves original steering once and installs the committed checkpoint" do
      alias IntellectualClub.Generation.{Context, Persistence}
      alias IntellectualClub.Test.GenerationRuntime.Barrier

      handoff =
        chat_tool_call("ack_compaction", "agent_management__handoff", %{
          "summary" => "Resume from checkpoint"
        })

      scripts = %{
        "/chat/completions" => [
          {200, blocked_chunks(:before_ack_compaction, chat_chunks([handoff]))},
          {200,
           blocked_chunks(:after_ack_compaction, chat_chunks([], "Completed after checkpoint"))}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, handoff_tool?: true)

      {:ok, _input} =
        Threads.add_message_to_end(chat, :user, "Work before checkpoint", actor: actor)

      {:ok, context} = GenerationSupervisor.start_generation(chat.id, actor: actor)
      assert_receive {:provider_waiting, :before_ack_compaction, provider}, 5_000

      gate =
        Barrier.gate_persistence(context.message_id,
          provider_completed: :stop,
          tool_followup: :stop
        )

      send(provider, :release_provider)
      completed = Barrier.await_persistence(:provider_completed, :stop)
      original = create_item!(actor, context.step_id, type: :steering, sequence: 2_000_000_000)

      create_content!(actor, original,
        kind: :text,
        content_text: "Original after-response instruction"
      )

      create_content!(actor, original,
        sequence: 1_000_000,
        kind: :opaque,
        content_json: %{"placement" => "after_response"}
      )

      assert {:ok, queued} =
               QueuedMessages.enqueue_steer(
                 context.message_id,
                 "Pending receiving-step instruction",
                 actor
               )

      Barrier.release(completed)
      committed = Barrier.await_persistence(:tool_followup, :stop)

      before_ack =
        Ash.get!(ChatMessage, context.message_id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      [source, receiving] = Enum.sort_by(before_ack.steps, & &1.sequence)

      assert Enum.filter(source.items, &(&1.type == :steering)) |> Enum.map(& &1.id) == [
               original.id
             ]

      assert [delivered_item] = Enum.filter(receiving.items, &(&1.type == :steering))
      assert item_text(delivered_item) == "Pending receiving-step instruction"
      assert {:ok, delivered} = QueuedMessages.get(queued.id, actor)
      assert delivered.status == :delivered
      assert delivered.steering_item_id == delivered_item.id
      Barrier.detach(gate)
      Barrier.crash(committed)
      assert_receive {:provider_waiting, :after_ack_compaction, after_provider}, 5_000
      [_initial, next_request] = scripted_requests(agent, "/chat/completions")

      for text <- ["Original after-response instruction", "Pending receiving-step instruction"] do
        assert Enum.count(
                 next_request["messages"],
                 &(&1["role"] == "user" and &1["content"] == text)
               ) == 1
      end

      assert StepRequests.request_for_step!(receiving.id, actor: actor)["messages"] ==
               next_request["messages"]

      assert Persistence.steering_specs_for_step!(source.id) |> Enum.map(& &1.item_id) == [
               original.id
             ]

      send(after_provider, :release_provider)
      done = wait_for_message!(context.message_id, actor, &(&1.status == :done))

      assert Enum.map(Enum.sort_by(done.steps, & &1.sequence), & &1.id) == [
               source.id,
               receiving.id
             ]

      assert Enum.count(Enum.flat_map(done.steps, & &1.items), &(&1.type == :steering)) == 2

      {:ok, _next_input} =
        Threads.add_message_to_end(chat, :user, "Next ordinary turn", actor: actor)

      future = Context.build!(chat.id, actor: actor)

      for text <- ["Original after-response instruction", "Pending receiving-step instruction"] do
        assert Enum.count(
                 future.request_payload["messages"],
                 &(&1["role"] == "user" and &1["content"] == text)
               ) == 1
      end

      [history, _checkpoint] = checkpoint_items(source)
      [archive] = Enum.filter(history.contents, &(&1.kind == :media))
      assert {:ok, {_file, archive_text}} = Files.load_payload(archive.file_id)
      assert length(Regex.scan(~r/Original after-response instruction/, archive_text)) == 1
      assert length(checkpoint_items(source)) == 2
    end

    test "compaction delivers pending steering to its receiving step and keeps follow-ups queued" do
      handoff =
        chat_tool_call("queued_handoff", "agent_management__handoff", %{
          "summary" => "Continue with queued instructions."
        })

      scripts = %{
        "/chat/completions" => [
          {200, blocked_chunks(:before_compaction, chat_chunks([handoff]))},
          {200, blocked_chunks(:after_compaction, chat_chunks([], "Compacted answer."))},
          {200, blocked_chunks(:follow_up, chat_chunks([], "Follow-up answer."))}
        ]
      }

      %{user: actor} = user_fixture()
      {base_url, agent} = start_scripted_server!(scripts)

      chat =
        create_chat_with_tool!(actor, base_url, :openrouter_chat_completion, handoff_tool?: true)

      {:ok, _user_message} =
        Threads.add_message_to_end(chat, :user, "Start the work", actor: actor)

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      assert_receive {:provider_waiting, :before_compaction, before_provider}, 2_000

      assert {:ok, follow_up} =
               QueuedMessages.enqueue_follow_up(
                 chat.id,
                 %{content: "Follow up after completion"},
                 actor
               )

      assert {:ok, steer} =
               QueuedMessages.enqueue_steer(
                 context.message_id,
                 "Steer the compacted answer",
                 actor
               )

      send(before_provider, :release_provider)
      assert_receive {:provider_waiting, :after_compaction, after_provider}, 2_000

      message =
        Ash.get!(ChatMessage, context.message_id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      assert message.status == :generating
      [source, receiving] = Enum.sort_by(message.steps, & &1.sequence)
      assert length(checkpoint_items(source)) == 2
      assert {:ok, delivered} = QueuedMessages.get(steer.id, actor)
      assert delivered.kind == :steer
      assert delivered.status == :delivered
      assert delivered.target_generation_message_id == message.id
      [steering] = Enum.filter(receiving.items, &(&1.type == :steering))
      assert steering.id == delivered.steering_item_id
      assert item_text(steering) == "Steer the compacted answer"
      assert {:ok, pending} = QueuedMessages.get(follow_up.id, actor)
      assert pending.chat_id == chat.id
      assert pending.anchor_message_id == message.id
      assert pending.status == :pending
      assert pending.assistant_message_id == nil
      [_initial, compacted] = scripted_requests(agent, "/chat/completions")
      assert Jason.encode!(compacted["messages"]) =~ "Steer the compacted answer"
      refute Jason.encode!(compacted["messages"]) =~ "Follow up after completion"
      assert_no_handoff_child!(chat.id, actor)

      send(after_provider, :release_provider)
      assert_receive {:provider_waiting, :follow_up, follow_up_provider}, 2_000
      assert wait_for_message!(message.id, actor, &(&1.status == :done)).status == :done
      assert {:ok, delivered_follow_up} = QueuedMessages.get(follow_up.id, actor)
      assert delivered_follow_up.chat_id == chat.id
      assert delivered_follow_up.status == :delivered
      assert delivered_follow_up.assistant_message_id != message.id
      follow_up_user = Ash.get!(ChatMessage, delivered_follow_up.user_message_id, actor: actor)
      assert follow_up_user.parent_id == message.id

      assert List.last(scripted_requests(agent, "/chat/completions"))["messages"]
             |> Jason.encode!() =~ "Follow up after completion"

      send(follow_up_provider, :release_provider)

      assert wait_for_message!(
               delivered_follow_up.assistant_message_id,
               actor,
               &(&1.status == :done)
             ).status == :done
    end
  end

  defp blocked_chunks(phase, chunks) do
    test_pid = self()

    fn ->
      send(test_pid, {:provider_waiting, phase, self()})

      receive do
        :release_provider -> chunks
      after
        5_000 -> raise "Provider barrier timed out: #{phase}"
      end
    end
  end

  defp chat_tool_call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }
  end

  defp chat_chunks(calls, text \\ "") do
    message = %{"role" => "assistant", "content" => text}
    message = if calls == [], do: message, else: Map.put(message, "tool_calls", calls)

    sse_chunks([
      %{
        "id" => "chatcmpl-#{System.unique_integer([:positive])}",
        "object" => "chat.completion",
        "created" => 1,
        "model" => "test-chat-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => message,
            "finish_reason" => if(calls == [], do: "stop", else: "tool_calls")
          }
        ]
      }
    ])
  end

  defp response_tool_call(id, name, args) do
    %{
      "id" => "fc_#{id}",
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => Jason.encode!(args)
    }
  end

  defp response_message(text) do
    %{
      "id" => "msg_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }
  end

  defp responses_chunks(id, output, context_limit? \\ false) do
    sse_chunks([
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => id,
          "object" => "response",
          "model" => "test-responses-model",
          "output" => output,
          "usage" => %{
            "input_tokens" => if(context_limit?, do: 4, else: 1),
            "output_tokens" => if(context_limit?, do: 3, else: 1)
          }
        }
      }
    ])
  end

  defp checkpoint_items(step) do
    step.items
    |> Enum.filter(&(&1.type in [:handoff_history, :handoff_message]))
    |> Enum.sort_by(& &1.sequence)
  end

  defp assert_no_handoff_child!(chat_id, actor) do
    assert [] ==
             Chat
             |> Ash.Query.filter(parent_chat_id == ^chat_id and parent_relation_kind == :handoff)
             |> Ash.read!(actor: actor)
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

  defp tool_result_texts(message) do
    message
    |> Map.get(:steps, [])
    |> Enum.flat_map(&Map.get(&1, :items, []))
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&Map.get(&1, :contents, []))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map(&(&1.content_text || ""))
  end

  defp compaction_payloads(message) do
    message
    |> Map.get(:steps, [])
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(fn step -> Enum.sort_by(step.items, & &1.sequence) end)
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&Map.get(&1, :contents, []))
    |> Enum.filter(&(&1.kind == :opaque))
    |> Enum.flat_map(fn content ->
      case get_in(content.content_json || %{}, ["raw", "compaction"]) do
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
