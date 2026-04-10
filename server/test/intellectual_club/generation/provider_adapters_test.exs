defmodule IntellectualClub.Generation.ProviderAdaptersTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.Adapters.OpenRouterChatCompletionAdapter
  alias IntellectualClub.Generation.Adapters.ResponsesAdapter
  alias IntellectualClub.Generation.RequestBuilder
  alias IntellectualClub.Generation.RuntimeTrace

  test "openrouter adapter builds initial request and snapshot from canonical chat history" do
    result =
      OpenRouterChatCompletionAdapter.build_initial_request(%{
        history: [%{role: "user", content: "Hello"}],
        system_prompt: "Be careful.",
        model_name: "openai/gpt-5-mini",
        parameters: %{"temperature" => 0.1},
        tools: [
          %{
            "type" => "function",
            "function" => %{
              "name" => "weather__get",
              "description" => "Get weather",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"city" => %{"type" => "string"}}
              }
            }
          }
        ],
        supports_image_input: false,
        cache_control_enabled: true
      })

    assert result.raw_request["model"] == "openai/gpt-5-mini"
    assert result.raw_request["temperature"] == 0.1
    assert is_list(result.raw_request["tools"])

    [system_message, user_message] = result.raw_request["messages"]

    assert system_message["role"] == "system"
    assert is_list(system_message["content"])
    assert List.last(system_message["content"])["cache_control"] == %{"type" => "ephemeral"}

    assert user_message["role"] == "user"
    assert is_list(user_message["content"])
    assert List.last(user_message["content"])["cache_control"] == %{"type" => "ephemeral"}

    assert result.request_snapshot.model_input == result.raw_request["messages"]
    assert result.request_snapshot.system_prompt == "Be careful."
    assert result.request_snapshot.history_length == 2
  end

  test "responses adapter builds initial request and snapshot from canonical history" do
    result =
      ResponsesAdapter.build_initial_request(%{
        history: [%{role: "user", content: "Hello"}],
        system_prompt: "Use tools when needed.",
        model_name: "gpt-5",
        parameters: %{"max_tokens" => 200},
        tools: [
          %{
            "type" => "function",
            "function" => %{
              "name" => "weather__get",
              "description" => "Get weather",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"city" => %{"type" => "string"}}
              }
            }
          }
        ],
        supports_image_input: false
      })

    assert result.raw_request["model"] == "gpt-5"
    assert result.raw_request["max_output_tokens"] == 200
    assert result.raw_request["store"] == false
    assert result.raw_request["instructions"] == "Use tools when needed."
    assert is_list(result.raw_request["input"])
    assert is_list(result.raw_request["tools"])

    assert result.request_snapshot.model_input == result.raw_request["input"]
    assert result.request_snapshot.system_prompt == "Use tools when needed."
  end

  test "openrouter adapter rebuilds followup chat request from previous raw request and tool results" do
    previous_messages = [
      %{
        "role" => "system",
        "content" => [
          %{"type" => "text", "text" => "System", "cache_control" => %{"type" => "ephemeral"}}
        ]
      },
      %{
        "role" => "user",
        "content" => [
          %{"type" => "text", "text" => "Hello", "cache_control" => %{"type" => "ephemeral"}}
        ]
      },
      %{"role" => "assistant", "content" => "Checking."},
      %{
        "role" => "tool",
        "tool_call_id" => "call_old",
        "content" => [
          %{"type" => "text", "text" => "old result", "cache_control" => %{"type" => "ephemeral"}}
        ]
      }
    ]

    raw_request =
      RequestBuilder.build_chat_completions_payload(
        "openai/gpt-5-mini",
        %{"temperature" => 0},
        previous_messages,
        tools: []
      )

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: raw_request,
        raw_response: %{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => "Checking again."
              }
            }
          ]
        }
      )

    results = [
      %{
        call_id: "call_new",
        name: "weather__get",
        args: %{"city" => "Paris"},
        raw: %{
          "id" => "call_new",
          "type" => "function",
          "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
        },
        text: ~s({"temperature":18.5}),
        result_raw: %{"temperature" => 18.5},
        media_contents: [],
        artifact_contents: []
      }
    ]

    followup =
      OpenRouterChatCompletionAdapter.build_followup_request(%{
        context: %{
          cache_control_enabled: true,
          history_length: 2,
          model_name: "openai/gpt-5-mini",
          parameters: %{"temperature" => 0},
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: []
      })

    messages = followup.raw_request["messages"]
    old_tool_message = Enum.at(messages, 3)
    new_tool_message = List.last(messages)

    assert old_tool_message["tool_call_id"] == "call_old"

    assert Enum.all?(old_tool_message["content"], fn part ->
             not Map.has_key?(part, "cache_control")
           end)

    assert new_tool_message["role"] == "tool"
    assert new_tool_message["tool_call_id"] == "call_new"
    assert is_list(new_tool_message["content"])
    assert List.last(new_tool_message["content"])["cache_control"] == %{"type" => "ephemeral"}

    assert followup.request_snapshot.history_length == 2

    assert RuntimeTrace.text_for_item_type(followup.runtime_step, :tool_result) ==
             ~s({"temperature":18.5})
  end

  test "responses adapter rebuilds followup request from previous raw request raw response and tool results" do
    input_items = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "Hello"}]
      }
    ]

    raw_request =
      RequestBuilder.build_responses_payload_from_input_items(
        "gpt-5",
        %{},
        input_items,
        include: ["reasoning.encrypted_content"],
        instructions: "System",
        tools: []
      )

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: raw_request,
        raw_response: %{
          "output" => [
            %{"type" => "reasoning", "id" => "rs_123", "summary" => []},
            %{
              "type" => "function_call",
              "id" => "fc_1",
              "call_id" => "call_1",
              "name" => "weather__get",
              "arguments" => ~s({"city":"Paris"})
            }
          ]
        }
      )

    results = [
      %{
        call_id: "call_1",
        name: "weather__get",
        raw: %{
          "id" => "fc_1",
          "type" => "function_call",
          "call_id" => "call_1",
          "name" => "weather__get",
          "arguments" => ~s({"city":"Paris"})
        },
        text: ~s({"temperature":18.5}),
        result_raw: %{"temperature" => 18.5},
        media_contents: [],
        artifact_contents: []
      }
    ]

    followup =
      ResponsesAdapter.build_followup_request(%{
        context: %{
          provider_base_url: "https://openrouter.ai/api/v1",
          model_name: "gpt-5",
          parameters: %{},
          system_prompt: "System",
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: []
      })

    input = followup.raw_request["input"]

    assert Enum.at(input, 0) == hd(input_items)

    assert Enum.any?(input, fn item ->
             item["type"] == "reasoning" and not Map.has_key?(item, "id")
           end)

    assert Enum.any?(input, fn item ->
             item["type"] == "function_call" and item["call_id"] == "call_1"
           end)

    assert Enum.any?(input, fn item ->
             item["type"] == "function_call_output" and item["call_id"] == "call_1" and
               item["output"] == ~s({"temperature":18.5})
           end)

    assert followup.request_snapshot.system_prompt == "System"

    assert RuntimeTrace.text_for_item_type(followup.runtime_step, :tool_result) ==
             ~s({"temperature":18.5})
  end
end
