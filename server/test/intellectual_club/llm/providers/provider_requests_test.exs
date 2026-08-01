defmodule IntellectualClub.Llm.Providers.ProviderRequestsTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Llm.Providers.Responses
  alias IntellectualClub.Llm.Providers.ResponsesWss
  alias IntellectualClub.Llm.Providers.Common.RequestBuilder
  alias IntellectualClub.Generation.RuntimeTrace

  test "openrouter provider builds initial request and snapshot from canonical chat history" do
    result =
      OpenRouterChatCompletion.build_initial_request(%{
        history: [%{role: :user, content: "Hello"}],
        system_prompt: "Be careful.",
        model_name: "openai/gpt-5-mini",
        parameters: %{"temperature" => 0.1},
        chat_id: 123,
        conversation_affinity_id: 77,
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
    assert result.raw_request["session_id"] == "intellectual-club:chat:77"
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

  test "NVIDIA Build provider builds a Chat Completions request without OpenRouter fields" do
    result =
      NvidiaBuildChatCompletion.build_initial_request(%{
        history: [%{role: :user, content: "Hello"}],
        system_prompt: "Be careful.",
        model_name: "nvidia/nemotron-3-nano-30b-a3b",
        parameters: %{"reasoning_effort" => "high"},
        chat_id: 123,
        conversation_affinity_id: 77,
        tools: [],
        supports_image_input: false,
        cache_control_enabled: true
      })

    assert result.raw_request["model"] == "nvidia/nemotron-3-nano-30b-a3b"
    assert result.raw_request["reasoning_effort"] == "high"
    assert result.raw_request["stream"] == true
    assert result.raw_request["stream_options"] == %{"include_usage" => true}
    refute Map.has_key?(result.raw_request, "session_id")

    [system_message, user_message] = result.raw_request["messages"]
    assert system_message == %{"role" => "system", "content" => "Be careful."}
    assert user_message == %{"role" => "user", "content" => "Hello"}
    assert result.request_snapshot.history_length == nil
  end

  test "responses provider builds initial request and snapshot from canonical history" do
    result =
      Responses.build_initial_request(%{
        history: [%{role: :user, content: "Hello"}],
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
        supports_image_input: false,
        chat_id: 123,
        owner_id: 456
      })

    assert result.raw_request["model"] == "gpt-5"
    assert result.raw_request["max_output_tokens"] == 200
    assert result.raw_request["store"] == false
    assert result.raw_request["prompt_cache_key"] == "intellectual-club:user:456"
    assert result.raw_request["instructions"] == "Use tools when needed."
    assert is_list(result.raw_request["input"])
    assert is_list(result.raw_request["tools"])

    assert result.request_snapshot.model_input == result.raw_request["input"]
    assert result.request_snapshot.system_prompt == "Use tools when needed."

    assert Responses.apply_prompt_cache_key(
             %{"prompt_cache_key" => "intellectual-club:chat:123"},
             %{owner_id: 456}
           ) == %{"prompt_cache_key" => "intellectual-club:user:456"}
  end

  test "responses_wss provider metadata and request building delegate to responses provider" do
    responses_metadata = Responses.metadata()
    responses_wss_metadata = ResponsesWss.metadata()

    assert responses_wss_metadata.type == "responses_wss"
    assert responses_wss_metadata.label == "Responses API (WSS)"
    assert responses_wss_metadata.default_auth_method == responses_metadata.default_auth_method
    assert responses_wss_metadata.auth_methods == responses_metadata.auth_methods
    assert responses_wss_metadata.base_url_options == responses_metadata.base_url_options
    assert responses_wss_metadata.default_base_url == responses_metadata.default_base_url

    assert responses_wss_metadata.supports_model_discovery ==
             responses_metadata.supports_model_discovery

    opts = %{
      history: [%{role: :user, content: "Hello"}],
      system_prompt: "Use tools when needed.",
      model_name: "gpt-5",
      parameters: %{"max_tokens" => 200},
      tools: [],
      supports_image_input: false,
      chat_id: 123,
      owner_id: 456
    }

    assert ResponsesWss.build_initial_request(opts) == Responses.build_initial_request(opts)

    assert ResponsesWss.build_initial_request(opts).raw_request["prompt_cache_key"] ==
             "intellectual-club:user:456"

    raw_request = %{"model" => "gpt-5", "input" => [], "instructions" => "System"}
    assert ResponsesWss.request_snapshot(raw_request) == Responses.request_snapshot(raw_request)
  end

  test "responses provider merges configured hosted tools with generated function tools" do
    hosted_tool = %{
      "type" => "web_search",
      "filters" => %{"allowed_domains" => ["openai.com"]},
      "external_web_access" => false
    }

    result =
      Responses.build_initial_request(%{
        history: [%{role: :user, content: "Search"}],
        system_prompt: "Use tools when needed.",
        model_name: "gpt-5",
        parameters: %{
          "tools" => [
            hosted_tool,
            %{
              "type" => "function",
              "name" => "weather__get",
              "description" => "Stale configured function",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"stale" => %{"type" => "string"}}
              }
            }
          ],
          "include" => ["web_search_call.action.sources"]
        },
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

    assert result.raw_request["include"] == [
             "web_search_call.action.sources",
             "reasoning.encrypted_content"
           ]

    assert result.raw_request["tools"] == [
             hosted_tool,
             %{
               "type" => "function",
               "name" => "weather__get",
               "description" => "Get weather",
               "parameters" => %{
                 "type" => "object",
                 "properties" => %{"city" => %{"type" => "string"}}
               },
               "strict" => nil
             }
           ]
  end

  test "google interactions provider builds stateless initial request from canonical history" do
    result =
      GoogleInteractions.build_initial_request(%{
        history: [%{role: :user, content: "Hello"}],
        system_prompt: "Use tools when needed.",
        model_name: "gemini-2.5-flash-lite",
        parameters: %{"temperature" => 0.1, "max_tokens" => 64},
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

    assert result.raw_request["model"] == "gemini-2.5-flash-lite"
    assert result.raw_request["stream"] == true
    assert result.raw_request["store"] == false
    assert result.raw_request["system_instruction"] == "Use tools when needed."

    assert result.raw_request["generation_config"] == %{
             "temperature" => 0.1,
             "max_output_tokens" => 64
           }

    assert result.raw_request["input"] == [
             %{
               "type" => "user_input",
               "content" => [%{"type" => "text", "text" => "Hello"}]
             }
           ]

    assert result.raw_request["tools"] == [
             %{
               "type" => "function",
               "name" => "weather__get",
               "description" => "Get weather",
               "parameters" => %{
                 "type" => "object",
                 "properties" => %{"city" => %{"type" => "string"}}
               }
             }
           ]

    assert result.request_snapshot.model_input == result.raw_request["input"]
    assert result.request_snapshot.system_prompt == "Use tools when needed."
  end

  test "google interactions provider rebuilds stateless followup with function results" do
    initial =
      GoogleInteractions.build_initial_request(%{
        history: [%{role: :user, content: "Weather in Paris?"}],
        system_prompt: "System",
        model_name: "gemini-2.5-flash-lite",
        parameters: %{"temperature" => 0},
        tools: [],
        supports_image_input: false
      })

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: initial.raw_request,
        raw_response: %{
          "steps" => [
            %{
              "type" => "thought",
              "signature" => "thought_sig_1",
              "summary" => [%{"type" => "text", "text" => "Need current weather."}]
            },
            %{
              "type" => "function_call",
              "id" => "call_1",
              "signature" => "sig_1",
              "name" => "weather__get",
              "arguments" => %{"city" => "Paris"}
            }
          ]
        }
      )

    results = [
      %{
        call_id: "call_1",
        name: "weather__get",
        raw: %{
          "type" => "function_call",
          "id" => "call_1",
          "signature" => "sig_1",
          "name" => "weather__get",
          "arguments" => %{"city" => "Paris"}
        },
        text: ~s({"temperature":18.5}),
        result_raw: %{"temperature" => 18.5},
        media_contents: [],
        artifact_contents: []
      }
    ]

    followup =
      GoogleInteractions.build_followup_request(%{
        context: %{
          model_name: "gemini-2.5-flash-lite",
          parameters: %{"temperature" => 0},
          system_prompt: "System",
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: []
      })

    assert followup.raw_request["system_instruction"] == "System"
    assert followup.raw_request["generation_config"] == %{"temperature" => 0}

    assert followup.raw_request["input"] == [
             %{
               "type" => "user_input",
               "content" => [%{"type" => "text", "text" => "Weather in Paris?"}]
             },
             %{
               "type" => "thought",
               "signature" => "thought_sig_1",
               "summary" => [%{"type" => "text", "text" => "Need current weather."}]
             },
             %{
               "type" => "function_call",
               "id" => "call_1",
               "signature" => "sig_1",
               "name" => "weather__get",
               "arguments" => %{"city" => "Paris"}
             },
             %{
               "type" => "function_result",
               "call_id" => "call_1",
               "name" => "weather__get",
               "result" => [%{"type" => "text", "text" => ~s({"temperature":18.5})}]
             }
           ]

    assert RuntimeTrace.text_for_item_type(followup.runtime_step, :tool_result) ==
             ~s({"temperature":18.5})
  end

  test "google interactions provider preserves a signed parallel call batch and closes every call" do
    initial =
      GoogleInteractions.build_initial_request(%{
        history: [%{role: :user, content: "Split the work"}],
        system_prompt: "System",
        model_name: "gemini-3.1-pro-preview",
        parameters: %{},
        tools: [],
        supports_image_input: false
      })

    function_calls = [
      %{
        "type" => "function_call",
        "id" => "call_a",
        "signature" => "parallel_batch_signature",
        "name" => "agent_management__fork",
        "arguments" => %{"task" => "Branch A"}
      },
      %{
        "type" => "function_call",
        "id" => "call_b",
        "name" => "agent_management__fork",
        "arguments" => %{"task" => "Branch B"}
      }
    ]

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: initial.raw_request,
        raw_response: %{"steps" => function_calls}
      )

    results = [
      %{
        call_id: "call_a",
        name: "agent_management__fork",
        text: "Skipped in this forked branch. Do not retry it.",
        result_raw: %{"fork_skipped" => %{"skipped" => true}},
        media_contents: [],
        artifact_contents: []
      },
      %{
        call_id: "call_b",
        name: "agent_management__fork",
        text: "Fork branch initialized. The task follows as a user instruction.",
        result_raw: %{"fork_instruction" => %{"subagent" => true, "task" => "Branch B"}},
        media_contents: [],
        artifact_contents: []
      }
    ]

    followup =
      GoogleInteractions.build_followup_request(%{
        context: %{
          model_name: "gemini-3.1-pro-preview",
          parameters: %{},
          system_prompt: "System",
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: []
      })

    steering_text =
      "You are now operating in a forked subagent branch. Execute only the task below.\n\n" <>
        "Task:\nBranch B"

    steered =
      GoogleInteractions.inject_steering(
        followup.raw_request,
        [%{text: steering_text, placement: :after_response}],
        %{}
      )

    [_user_input, first_call, second_call, first_result, second_result, steering] =
      steered.raw_request["input"]

    assert first_call == Enum.at(function_calls, 0)
    assert second_call == Enum.at(function_calls, 1)
    assert first_result["type"] == "function_result"
    assert first_result["call_id"] == "call_a"
    assert second_result["type"] == "function_result"
    assert second_result["call_id"] == "call_b"

    assert second_result["result"] == [
             %{
               "type" => "text",
               "text" => "Fork branch initialized. The task follows as a user instruction."
             }
           ]

    assert steering == %{
             "type" => "user_input",
             "content" => [%{"type" => "text", "text" => steering_text}]
           }
  end

  test "anthropic provider builds initial messages request from canonical chat history" do
    result =
      AnthropicMessages.build_initial_request(%{
        history: [%{role: :user, content: "Hello"}],
        system_prompt: "Use tools when needed.",
        model_name: "claude-sonnet-4-20250514",
        parameters: %{"max_tokens" => 200, "temperature" => 0.1},
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

    assert result.raw_request["model"] == "claude-sonnet-4-20250514"
    assert result.raw_request["max_tokens"] == 200
    assert result.raw_request["temperature"] == 0.1
    assert result.raw_request["stream"] == true
    assert result.raw_request["system"] == "Use tools when needed."

    assert result.raw_request["messages"] == [
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "Hello"}]}
           ]

    assert result.raw_request["tools"] == [
             %{
               "name" => "weather__get",
               "description" => "Get weather",
               "input_schema" => %{
                 "type" => "object",
                 "properties" => %{"city" => %{"type" => "string"}}
               }
             }
           ]

    assert result.request_snapshot.model_input == result.raw_request["messages"]
    assert result.request_snapshot.system_prompt == "Use tools when needed."
  end

  test "anthropic provider uses 32k max tokens by default" do
    result =
      AnthropicMessages.build_initial_request(%{
        history: [%{role: :user, content: "Hello"}],
        system_prompt: "Use tools when needed.",
        model_name: "claude-sonnet-4-20250514",
        parameters: %{},
        tools: [],
        supports_image_input: false
      })

    assert result.raw_request["max_tokens"] == 32_768
  end

  test "anthropic provider adds cache control markers only when requested" do
    base_opts = %{
      history: [%{role: :user, content: "Hello"}],
      system_prompt: "Use tools when needed.",
      model_name: "claude-sonnet-4-20250514",
      parameters: %{"max_tokens" => 200},
      tools: [],
      supports_image_input: false
    }

    disabled = AnthropicMessages.build_initial_request(base_opts)

    assert disabled.raw_request["system"] == "Use tools when needed."

    refute disabled.raw_request["messages"]
           |> List.first()
           |> Map.fetch!("content")
           |> List.first()
           |> Map.has_key?("cache_control")

    assert disabled.request_snapshot.history_length == nil

    enabled =
      base_opts
      |> Map.put(:cache_control_enabled, true)
      |> AnthropicMessages.build_initial_request()

    assert enabled.raw_request["system"] == [
             %{
               "type" => "text",
               "text" => "Use tools when needed.",
               "cache_control" => %{"type" => "ephemeral"}
             }
           ]

    [user_message] = enabled.raw_request["messages"]
    assert user_message["role"] == "user"
    assert List.last(user_message["content"])["cache_control"] == %{"type" => "ephemeral"}
    assert enabled.request_snapshot.history_length == 1
  end

  test "openrouter provider rebuilds followup chat request from previous raw request and tool results" do
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
      OpenRouterChatCompletion.build_followup_request(%{
        context: %{
          cache_control_enabled: true,
          chat_id: 123,
          conversation_affinity_id: 77,
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

    assert followup.raw_request["session_id"] == "intellectual-club:chat:77"
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

  test "NVIDIA Build provider rebuilds followup chat request without OpenRouter fields" do
    previous_messages = [
      %{
        "role" => "system",
        "content" => [
          %{"type" => "text", "text" => "System", "cache_control" => %{"type" => "ephemeral"}}
        ]
      },
      %{"role" => "user", "content" => "Hello"}
    ]

    raw_request =
      RequestBuilder.build_chat_completions_payload(
        "nvidia/nemotron-3-nano-30b-a3b",
        %{
          "reasoning_budget" => 2_048,
          "session_id" => "legacy-session",
          "stream_options" => %{"custom" => true}
        },
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
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_weather",
                    "type" => "function",
                    "function" => %{
                      "name" => "weather__get",
                      "arguments" => ~s({"city":"Paris"})
                    }
                  }
                ]
              }
            }
          ]
        }
      )

    followup =
      NvidiaBuildChatCompletion.build_followup_request(%{
        context: %{
          cache_control_enabled: true,
          history_length: 2,
          model_name: "nvidia/nemotron-3-nano-30b-a3b",
          parameters: %{},
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: [
          %{
            call_id: "call_weather",
            name: "weather__get",
            args: %{"city" => "Paris"},
            raw: %{
              "id" => "call_weather",
              "type" => "function",
              "function" => %{
                "name" => "weather__get",
                "arguments" => ~s({"city":"Paris"})
              }
            },
            text: ~s({"temperature":18.5}),
            result_raw: %{"temperature" => 18.5},
            media_contents: [],
            artifact_contents: []
          }
        ],
        tools: []
      })

    refute Map.has_key?(followup.raw_request, "session_id")
    assert followup.raw_request["reasoning_budget"] == 2_048
    assert followup.raw_request["stream_options"] == %{"custom" => true, "include_usage" => true}
    assert followup.request_snapshot.history_length == nil

    assert Enum.any?(followup.raw_request["messages"], fn message ->
             message["role"] == "tool" and message["tool_call_id"] == "call_weather"
           end)

    refute followup.raw_request["messages"]
           |> inspect()
           |> String.contains?("cache_control")
  end

  test "openrouter provider closes every parallel tool call before one combined media message" do
    raw_request =
      RequestBuilder.build_chat_completions_payload(
        "moonshotai/kimi-k3",
        %{},
        [%{"role" => "user", "content" => "Inspect both images."}],
        tools: []
      )

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: raw_request,
        raw_response: %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => ""}}
          ]
        }
      )

    first_file_id = "11111111-1111-4111-8111-111111111111"
    second_file_id = "22222222-2222-4222-8222-222222222222"

    results = [
      chat_result("read_image_1", "read_image", [result_media(2, 41, first_file_id, "one.png")]),
      chat_result("shell_2", "run_command", []),
      chat_result("read_image_3", "read_image", [
        result_media(2, 42, second_file_id, "two.png")
      ])
    ]

    followup =
      OpenRouterChatCompletion.build_followup_request(%{
        context: %{
          cache_control_enabled: false,
          chat_id: 131,
          model_name: "moonshotai/kimi-k3",
          parameters: %{},
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: []
      })

    [_initial_user, assistant | followup_messages] = followup.raw_request["messages"]
    assert assistant["role"] == "assistant"

    assert Enum.map(followup_messages, & &1["role"]) == ["tool", "tool", "tool", "user"]

    assert Enum.map(Enum.take(followup_messages, 3), & &1["tool_call_id"]) == [
             "read_image_1",
             "shell_2",
             "read_image_3"
           ]

    media_message = List.last(followup_messages)

    assert is_binary(media_message["content"])
    assert String.contains?(media_message["content"], first_file_id)
    assert String.contains?(media_message["content"], second_file_id)

    {first_position, _length} = :binary.match(media_message["content"], "one.png")
    {second_position, _length} = :binary.match(media_message["content"], "two.png")
    assert first_position < second_position
  end

  test "responses provider rebuilds followup request from previous raw request raw response and tool results" do
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
      Responses.build_followup_request(%{
        context: %{
          provider_base_url: "https://openrouter.ai/api/v1",
          model_name: "gpt-5",
          parameters: %{},
          system_prompt: "System",
          supports_image_input: false,
          chat_id: 123,
          owner_id: 456
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
    assert followup.raw_request["prompt_cache_key"] == "intellectual-club:user:456"

    assert RuntimeTrace.text_for_item_type(followup.runtime_step, :tool_result) ==
             ~s({"temperature":18.5})
  end

  test "responses provider preserves hosted tools when building followup requests" do
    hosted_tool = %{
      "type" => "web_search",
      "filters" => %{"allowed_domains" => ["openai.com"]},
      "external_web_access" => false
    }

    initial =
      Responses.build_initial_request(%{
        history: [%{role: :user, content: "Weather in Paris?"}],
        system_prompt: "System",
        model_name: "gpt-5",
        parameters: %{
          "tools" => [hosted_tool],
          "include" => ["web_search_call.action.sources"]
        },
        tools: [
          %{
            "type" => "function",
            "function" => %{
              "name" => "weather__get",
              "description" => "Old weather tool",
              "parameters" => %{"type" => "object", "properties" => %{}}
            }
          }
        ],
        supports_image_input: false
      })

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: initial.raw_request,
        raw_response: %{
          "output" => [
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
      Responses.build_followup_request(%{
        context: %{
          provider_base_url: "https://api.openai.com/v1",
          model_name: "gpt-5",
          parameters: %{},
          system_prompt: "System",
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: [
          %{
            "type" => "function",
            "function" => %{
              "name" => "weather__get",
              "description" => "Current weather tool",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"city" => %{"type" => "string"}}
              }
            }
          }
        ]
      })

    assert followup.raw_request["include"] == [
             "web_search_call.action.sources",
             "reasoning.encrypted_content"
           ]

    assert followup.raw_request["tools"] == [
             hosted_tool,
             %{
               "type" => "function",
               "name" => "weather__get",
               "description" => "Current weather tool",
               "parameters" => %{
                 "type" => "object",
                 "properties" => %{"city" => %{"type" => "string"}}
               },
               "strict" => nil
             }
           ]
  end

  test "anthropic provider rebuilds followup request with tool result blocks" do
    raw_request =
      AnthropicMessages.build_initial_request(%{
        history: [%{role: :user, content: "Weather in Paris?"}],
        system_prompt: "System",
        model_name: "claude-sonnet-4-20250514",
        parameters: %{"max_tokens" => 200},
        tools: [],
        supports_image_input: false
      }).raw_request

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: raw_request,
        raw_response: %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Checking."},
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "weather__get",
              "input" => %{"city" => "Paris"}
            }
          ]
        }
      )

    results = [
      %{
        call_id: "toolu_1",
        name: "weather__get",
        raw: %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "weather__get",
          "input" => %{"city" => "Paris"}
        },
        text: ~s({"temperature":18.5}),
        result_raw: %{"temperature" => 18.5},
        media_contents: [],
        artifact_contents: []
      }
    ]

    followup =
      AnthropicMessages.build_followup_request(%{
        context: %{
          model_name: "claude-sonnet-4-20250514",
          parameters: %{"max_tokens" => 200},
          system_prompt: "System",
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: []
      })

    assert followup.raw_request["system"] == "System"

    assert List.last(followup.raw_request["messages"]) == %{
             "role" => "user",
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_1",
                 "content" => ~s({"temperature":18.5})
               }
             ]
           }

    assert Enum.at(followup.raw_request["messages"], -2) == %{
             "role" => "assistant",
             "content" => [
               %{"type" => "text", "text" => "Checking."},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "weather__get",
                 "input" => %{"city" => "Paris"}
               }
             ]
           }

    assert RuntimeTrace.text_for_item_type(followup.runtime_step, :tool_result) ==
             ~s({"temperature":18.5})
  end

  test "anthropic provider preserves provider-native tools from previous raw request on followup" do
    native_tools = [
      %{
        "name" => "weather__get",
        "description" => "Get weather",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        },
        "cache_control" => %{"type" => "ephemeral"}
      }
    ]

    raw_request = %{
      "model" => "claude-sonnet-4-20250514",
      "max_tokens" => 200,
      "stream" => true,
      "system" => "System",
      "messages" => [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "Weather?"}]}
      ],
      "tools" => native_tools,
      "tool_choice" => %{"type" => "auto"}
    }

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: raw_request,
        raw_response: %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "weather__get",
              "input" => %{"city" => "Paris"}
            }
          ]
        }
      )

    results = [
      %{
        call_id: "toolu_1",
        name: "weather__get",
        raw: %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "weather__get",
          "input" => %{"city" => "Paris"}
        },
        text: ~s({"temperature":18.5}),
        result_raw: %{"temperature" => 18.5},
        media_contents: [],
        artifact_contents: []
      }
    ]

    followup =
      AnthropicMessages.build_followup_request(%{
        context: %{
          model_name: "claude-sonnet-4-20250514",
          parameters: %{"max_tokens" => 200},
          system_prompt: "System",
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: [
          %{
            "type" => "function",
            "function" => %{
              "name" => "weather__get",
              "description" => "Duplicate common schema",
              "parameters" => %{"type" => "object"}
            }
          }
        ]
      })

    assert followup.raw_request["tools"] == native_tools
    assert followup.raw_request["tool_choice"] == %{"type" => "auto"}
  end

  test "anthropic provider moves cache control marker to latest followup message" do
    initial =
      AnthropicMessages.build_initial_request(%{
        history: [%{role: :user, content: "Weather in Paris?"}],
        system_prompt: "System",
        model_name: "claude-sonnet-4-20250514",
        parameters: %{"max_tokens" => 200},
        tools: [],
        supports_image_input: false,
        cache_control_enabled: true
      })

    previous_raw_request =
      update_in(initial.raw_request, ["messages"], fn messages ->
        messages ++
          [
            %{
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Checking previous."},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_old",
                  "name" => "weather__get",
                  "input" => %{"city" => "Paris"}
                }
              ]
            },
            %{
              "role" => "user",
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "toolu_old",
                  "content" => ~s({"temperature":17.0}),
                  "cache_control" => %{"type" => "ephemeral"}
                }
              ]
            }
          ]
      end)

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: previous_raw_request,
        raw_response: %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Checking again."},
            %{
              "type" => "tool_use",
              "id" => "toolu_new",
              "name" => "weather__get",
              "input" => %{"city" => "Paris"}
            }
          ]
        }
      )

    results = [
      %{
        call_id: "toolu_new",
        name: "weather__get",
        raw: %{
          "type" => "tool_use",
          "id" => "toolu_new",
          "name" => "weather__get",
          "input" => %{"city" => "Paris"}
        },
        text: ~s({"temperature":18.5}),
        result_raw: %{"temperature" => 18.5},
        media_contents: [],
        artifact_contents: []
      }
    ]

    followup =
      AnthropicMessages.build_followup_request(%{
        context: %{
          cache_control_enabled: true,
          history_length: initial.request_snapshot.history_length,
          model_name: "claude-sonnet-4-20250514",
          parameters: %{"max_tokens" => 200},
          system_prompt: "System",
          supports_image_input: false
        },
        runtime_step: runtime_step,
        results: results,
        tools: []
      })

    messages = followup.raw_request["messages"]
    initial_user = Enum.at(messages, 0)
    old_tool_result = Enum.at(messages, 2)
    new_tool_result = List.last(messages)

    assert List.last(initial_user["content"])["cache_control"] == %{"type" => "ephemeral"}

    refute old_tool_result["content"]
           |> List.first()
           |> Map.has_key?("cache_control")

    assert new_tool_result["content"] == [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_new",
               "content" => ~s({"temperature":18.5}),
               "cache_control" => %{"type" => "ephemeral"}
             }
           ]

    assert followup.request_snapshot.history_length == 1
  end

  defp chat_result(call_id, name, media_contents) do
    %{
      call_id: call_id,
      name: name,
      args: %{},
      raw: %{
        "id" => call_id,
        "type" => "function",
        "function" => %{"name" => name, "arguments" => "{}"}
      },
      text: "done",
      result_raw: %{"ok" => true},
      media_contents: media_contents,
      artifact_contents: []
    }
  end

  defp result_media(sequence, id, external_id, filename) do
    %{
      kind: :media,
      sequence: sequence,
      external_id:
        "33333333-3333-4333-8333-#{id |> Integer.to_string() |> String.pad_leading(12, "0")}",
      file_id: id,
      file: %{
        id: id,
        external_id: external_id,
        filename: filename,
        mime_type: "image/png",
        size_bytes: 3,
        sha256: String.duplicate("a", 64)
      }
    }
  end
end
