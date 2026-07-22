defmodule IntellectualClub.Llm.Providers.SteeringProjectionTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Chat.HandoffRolloff
  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.Common.ChatHistory
  alias IntellectualClub.Llm.Providers.Demo
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.Llm.Providers.GoogleInteractions.Payload, as: GooglePayload
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Llm.Providers.Responses
  alias IntellectualClub.Llm.Providers.Responses.HistoryInput
  alias IntellectualClub.Llm.Providers.ResponsesWss

  test "responses steering is appended after the existing live input" do
    raw_request = %{
      "model" => "gpt-5",
      "input" => [
        user_responses_message("Start"),
        %{"type" => "reasoning", "encrypted_content" => "opaque"},
        %{
          "type" => "function_call_output",
          "call_id" => "call_1",
          "output" => "done"
        }
      ],
      "instructions" => "System",
      "custom_parameter" => true
    }

    steering = [%{text: "Change direction", placement: :after_response}, "And be concise"]
    result = Responses.inject_steering(raw_request, steering, %{})

    assert result.raw_request["input"] ==
             raw_request["input"] ++
               [
                 user_responses_message("Change direction"),
                 user_responses_message("And be concise")
               ]

    assert result.raw_request["custom_parameter"] == true
    assert result.request_snapshot.model_input == result.raw_request["input"]

    assert ResponsesWss.inject_steering(raw_request, steering, %{}) == result
  end

  test "anthropic steering is merged after tool results in the trailing user message" do
    raw_request = %{
      "model" => "claude-sonnet-4",
      "messages" => [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "Start"}]},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => %{}}
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_1",
              "content" => "done"
            }
          ]
        }
      ],
      "max_tokens" => 100,
      "stream" => true
    }

    result =
      AnthropicMessages.inject_steering(
        raw_request,
        [%{text: "Change direction"}, %{text: "And be concise"}],
        %{cache_control_enabled: false}
      )

    assert List.last(result.raw_request["messages"])["content"] == [
             %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "done"},
             %{"type" => "text", "text" => "Change direction"},
             %{"type" => "text", "text" => "And be concise"}
           ]

    assert result.request_snapshot.model_input == result.raw_request["messages"]
  end

  test "openrouter steering follows all tool result messages" do
    raw_request = %{
      "model" => "openai/gpt-5",
      "messages" => [
        %{"role" => "user", "content" => "Start"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "type" => "function",
              "function" => %{"name" => "lookup", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "call_1", "content" => "done"}
      ],
      "stream" => true
    }

    result =
      OpenRouterChatCompletion.inject_steering(
        raw_request,
        ["Change direction", %{text: "And be concise"}],
        %{cache_control_enabled: false}
      )

    assert Enum.take(result.raw_request["messages"], -3) == [
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "done"},
             %{"role" => "user", "content" => "Change direction"},
             %{"role" => "user", "content" => "And be concise"}
           ]

    assert result.request_snapshot.model_input == result.raw_request["messages"]
  end

  test "google steering follows all function results" do
    raw_request = %{
      "model" => "gemini-2.5-flash",
      "input" => [
        %{"type" => "user_input", "content" => [%{"type" => "text", "text" => "Start"}]},
        %{"type" => "function_result", "call_id" => "call_1", "result" => "done"}
      ],
      "stream" => true,
      "store" => false
    }

    result =
      GoogleInteractions.inject_steering(
        raw_request,
        [%{text: "Change direction"}, "And be concise"],
        %{}
      )

    assert Enum.take(result.raw_request["input"], -3) == [
             %{"type" => "function_result", "call_id" => "call_1", "result" => "done"},
             google_user_input("Change direction"),
             google_user_input("And be concise")
           ]

    assert result.request_snapshot.model_input == result.raw_request["input"]
  end

  test "demo provider appends steering as chat user messages" do
    result =
      Demo.inject_steering(
        %{"messages" => [%{"role" => "user", "content" => "Start"}]},
        ["Change direction"],
        %{}
      )

    assert result.raw_request["messages"] == [
             %{"role" => "user", "content" => "Start"},
             %{"role" => "user", "content" => "Change direction"}
           ]
  end

  test "canonical steering is projected at its exact position for every history format" do
    history = canonical_history()

    assert HistoryInput.build_input_items(history) == [
             assistant_responses_message("Checking", "commentary"),
             %{
               "type" => "function_call",
               "id" => "fc_call_1",
               "call_id" => "call_1",
               "name" => "lookup",
               "arguments" => ~s({"query":"old"})
             },
             %{
               "type" => "function_call_output",
               "id" => "fco_call_1",
               "call_id" => "call_1",
               "output" => "done"
             },
             user_responses_message("Use the new source"),
             assistant_responses_message("Updated answer", "final_answer")
           ]

    assert ChatHistory.build_messages(history) == [
             %{
               "role" => "assistant",
               "content" => "Checking",
               "tool_calls" => [
                 %{
                   "id" => "call_1",
                   "type" => "function",
                   "function" => %{"name" => "lookup", "arguments" => ~s({"query":"old"})}
                 }
               ]
             },
             %{"role" => "tool", "content" => "done", "tool_call_id" => "call_1"},
             %{"role" => "user", "content" => "Use the new source"},
             %{"role" => "assistant", "content" => "Updated answer"}
           ]

    assert GooglePayload.build_input_steps(history) == [
             google_model_output("Checking"),
             %{
               "type" => "function_call",
               "id" => "call_1",
               "name" => "lookup",
               "arguments" => %{"query" => "old"}
             },
             %{
               "type" => "function_result",
               "call_id" => "call_1",
               "name" => "lookup",
               "result" => [%{"type" => "text", "text" => "done"}]
             },
             google_user_input("Use the new source"),
             google_model_output("Updated answer")
           ]
  end

  test "handoff item types preserve the ordinary user and assistant wire format" do
    history = [
      %{
        role: :user,
        steps: [%{sequence: 1, items: [trace_item(1, :handoff_request, "Prepare transfer")]}]
      },
      %{
        role: :assistant,
        steps: [%{sequence: 1, items: [trace_item(1, :handoff_summary, "Transfer ready")]}]
      },
      %{
        role: :user,
        steps: [%{sequence: 1, items: [trace_item(1, :handoff_context, "Continue here")]}]
      }
    ]

    assert HistoryInput.build_input_items(history) == [
             user_responses_message("Prepare transfer"),
             assistant_responses_message("Transfer ready", "final_answer"),
             user_responses_message("Continue here")
           ]

    assert ChatHistory.build_messages(history) == [
             %{"role" => "user", "content" => "Prepare transfer"},
             %{"role" => "assistant", "content" => "Transfer ready"},
             %{"role" => "user", "content" => "Continue here"}
           ]

    assert GooglePayload.build_input_steps(history) == [
             google_user_input("Prepare transfer"),
             google_model_output("Transfer ready"),
             google_user_input("Continue here")
           ]

    base_opts = %{
      history: history,
      system_prompt: nil,
      parameters: %{},
      tools: [],
      supports_image_input: false,
      cache_control_enabled: false
    }

    responses = Responses.build_initial_request(Map.put(base_opts, :model_name, "gpt-5"))

    assert responses.raw_request["input"] == [
             user_responses_message("Prepare transfer"),
             assistant_responses_message("Transfer ready", "final_answer"),
             user_responses_message("Continue here")
           ]

    openrouter =
      OpenRouterChatCompletion.build_initial_request(
        Map.put(base_opts, :model_name, "openai/gpt-5")
      )

    assert openrouter.raw_request["messages"] == [
             %{"role" => "user", "content" => "Prepare transfer"},
             %{"role" => "assistant", "content" => "Transfer ready"},
             %{"role" => "user", "content" => "Continue here"}
           ]

    anthropic =
      AnthropicMessages.build_initial_request(Map.put(base_opts, :model_name, "claude-sonnet-4"))

    assert anthropic.raw_request["messages"] == [
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "Prepare transfer"}]
             },
             %{
               "role" => "assistant",
               "content" => [%{"type" => "text", "text" => "Transfer ready"}]
             },
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "Continue here"}]}
           ]

    google =
      GoogleInteractions.build_initial_request(
        Map.put(base_opts, :model_name, "gemini-2.5-flash")
      )

    assert google.raw_request["input"] == [
             google_user_input("Prepare transfer"),
             google_model_output("Transfer ready"),
             google_user_input("Continue here")
           ]
  end

  test "structured handoff history has the same model projection for every provider" do
    history = [
      %{
        role: :user,
        steps: [
          %{
            sequence: 1,
            items: [
              %{
                sequence: 1,
                type: :handoff_history,
                contents: [
                  handoff_history_content(
                    1,
                    "Original goal",
                    "user",
                    "2026-07-22T10:30:00Z"
                  ),
                  handoff_history_content(
                    2,
                    "Completed step",
                    "assistant",
                    "2026-07-22T10:31:00Z"
                  )
                ]
              },
              trace_item(2, :handoff_message, "Continue from here.")
            ]
          }
        ]
      }
    ]

    expected_prompt =
      HandoffRolloff.render_prompt(
        [
          %{
            kind: :message,
            role: :user,
            timestamp: "2026-07-22T10:30:00Z",
            text: "Original goal"
          },
          %{
            kind: :message,
            role: :assistant,
            timestamp: "2026-07-22T10:31:00Z",
            text: "Completed step"
          }
        ],
        "Continue from here."
      )

    assert HistoryInput.build_input_items(history) == [user_responses_message(expected_prompt)]

    assert ChatHistory.build_messages(history) == [
             %{"role" => "user", "content" => expected_prompt}
           ]

    assert GooglePayload.build_input_steps(history) == [google_user_input(expected_prompt)]

    base_opts = %{
      history: history,
      system_prompt: nil,
      parameters: %{},
      tools: [],
      supports_image_input: false,
      cache_control_enabled: false
    }

    responses = Responses.build_initial_request(Map.put(base_opts, :model_name, "gpt-5"))
    assert responses.raw_request["input"] == [user_responses_message(expected_prompt)]

    openrouter =
      OpenRouterChatCompletion.build_initial_request(
        Map.put(base_opts, :model_name, "openai/gpt-5")
      )

    assert openrouter.raw_request["messages"] == [
             %{"role" => "user", "content" => expected_prompt}
           ]

    anthropic =
      AnthropicMessages.build_initial_request(Map.put(base_opts, :model_name, "claude-sonnet-4"))

    assert anthropic.raw_request["messages"] == [
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => expected_prompt}]
             }
           ]

    google =
      GoogleInteractions.build_initial_request(
        Map.put(base_opts, :model_name, "gemini-2.5-flash")
      )

    assert google.raw_request["input"] == [google_user_input(expected_prompt)]
  end

  test "leading canonical steering stays before a restarted provider response" do
    history = [
      %{
        role: :assistant,
        steps: [
          %{
            sequence: 1,
            items: [
              trace_item(1, :steering, "Do not make that change"),
              trace_item(2, :answer, "Understood")
            ]
          }
        ]
      }
    ]

    assert HistoryInput.build_input_items(history) == [
             user_responses_message("Do not make that change"),
             assistant_responses_message("Understood", "final_answer")
           ]

    assert ChatHistory.build_messages(history) == [
             %{"role" => "user", "content" => "Do not make that change"},
             %{"role" => "assistant", "content" => "Understood"}
           ]

    assert GooglePayload.build_input_steps(history) == [
             google_user_input("Do not make that change"),
             google_model_output("Understood")
           ]
  end

  defp canonical_history do
    [
      %{
        role: :assistant,
        steps: [
          %{
            sequence: 1,
            items: [
              trace_item(1, :answer, "Checking"),
              historical_reasoning_item(2),
              tool_call_item(3),
              tool_result_item(4),
              orphan_tool_call_item(5),
              trace_item(6, :steering, "Use the new source")
            ]
          },
          %{sequence: 2, items: [trace_item(1, :answer, "Updated answer")]}
        ]
      }
    ]
  end

  defp trace_item(sequence, type, text) do
    %{
      sequence: sequence,
      type: type,
      contents: [%{sequence: 1, kind: :text, content_text: text}]
    }
  end

  defp handoff_history_content(sequence, text, role, created_at) do
    %{
      sequence: sequence,
      kind: :text,
      content_text: text,
      content_json: %{
        "entry_kind" => "message",
        "role" => role,
        "created_at" => created_at
      }
    }
  end

  defp historical_reasoning_item(sequence) do
    %{
      sequence: sequence,
      type: :reasoning,
      contents: [
        %{sequence: 1, kind: :text, content_text: "Persisted reasoning must not be replayed"},
        %{
          sequence: 10_000,
          kind: :opaque,
          content_json: %{
            "google_interaction_step" => %{
              "type" => "thought",
              "signature" => "historical_thought_signature",
              "summary" => [
                %{"type" => "text", "text" => "Persisted reasoning must not be replayed"}
              ]
            }
          }
        }
      ]
    }
  end

  defp tool_call_item(sequence) do
    %{
      id: 101,
      sequence: sequence,
      type: :tool_call,
      contents: [
        %{
          sequence: 10_000,
          kind: :opaque,
          content_json: %{
            "tool_call_id" => "call_1",
            "name" => "lookup",
            "arguments" => %{"query" => "old"}
          }
        }
      ]
    }
  end

  defp tool_result_item(sequence) do
    %{
      sequence: sequence,
      type: :tool_result,
      tool_call_item_id: 101,
      contents: [
        %{sequence: 1, kind: :text, content_text: "done"},
        %{
          sequence: 10_000,
          kind: :opaque,
          content_json: %{"tool_call_id" => "call_1", "name" => "lookup"}
        }
      ]
    }
  end

  defp orphan_tool_call_item(sequence) do
    %{
      id: 102,
      sequence: sequence,
      type: :tool_call,
      contents: [
        %{
          sequence: 10_000,
          kind: :opaque,
          content_json: %{
            "tool_call_id" => "call_orphan",
            "name" => "lookup",
            "arguments" => %{"query" => "never completed"}
          }
        }
      ]
    }
  end

  defp user_responses_message(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp assistant_responses_message(text, phase) do
    %{
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "phase" => phase,
      "content" => [
        %{"type" => "output_text", "text" => text, "annotations" => []}
      ]
    }
  end

  defp google_user_input(text) do
    %{"type" => "user_input", "content" => [%{"type" => "text", "text" => text}]}
  end

  defp google_model_output(text) do
    %{"type" => "model_output", "content" => [%{"type" => "text", "text" => text}]}
  end
end
