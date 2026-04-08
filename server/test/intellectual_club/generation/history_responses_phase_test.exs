defmodule IntellectualClub.Generation.HistoryResponsesPhaseTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.History

  test "synthesizes commentary and final_answer phases for fallback assistant answers" do
    history = [
      %{
        role: :assistant,
        steps: [
          %{
            sequence: 1,
            items: [
              %{
                sequence: 1,
                type: :answer,
                contents: [
                  %{sequence: 1, kind: :text, content_text: "Let me check."}
                ]
              },
              %{
                sequence: 2,
                type: :tool_call,
                contents: [
                  %{sequence: 1, kind: :text, content_text: "Tool call: weather__get"},
                  %{
                    sequence: 2,
                    kind: :opaque,
                    content_json: %{
                      "type" => "function_call",
                      "id" => "fc_weather",
                      "call_id" => "call_weather",
                      "name" => "weather__get",
                      "arguments" => ~s({"city":"Paris"})
                    }
                  }
                ]
              },
              %{
                sequence: 3,
                type: :tool_result,
                contents: [
                  %{sequence: 1, kind: :text, content_text: ~s({"temperature":18.5})},
                  %{
                    sequence: 2,
                    kind: :opaque,
                    content_json: %{
                      "type" => "function_call_output",
                      "id" => "fco_weather",
                      "call_id" => "call_weather",
                      "output" => ~s({"temperature":18.5})
                    }
                  }
                ]
              }
            ]
          },
          %{
            sequence: 2,
            items: [
              %{
                sequence: 1,
                type: :answer,
                contents: [
                  %{sequence: 1, kind: :text, content_text: "It is 18.5°C in Paris."}
                ]
              }
            ]
          }
        ]
      }
    ]

    assert History.build_responses_input_items(history) == [
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "commentary",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Let me check.",
                   "annotations" => []
                 }
               ]
             },
             %{
               "type" => "function_call",
               "id" => "fc_weather",
               "call_id" => "call_weather",
               "name" => "weather__get",
               "arguments" => ~s({"city":"Paris"})
             },
             %{
               "type" => "function_call_output",
               "id" => "fco_weather",
               "call_id" => "call_weather",
               "output" => ~s({"temperature":18.5})
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "final_answer",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "It is 18.5°C in Paris.",
                   "annotations" => []
                 }
               ]
             }
           ]
  end

  test "preserves phase from stored responses assistant messages" do
    history = [
      %{
        role: :assistant,
        steps: [
          %{
            sequence: 1,
            items: [
              %{
                sequence: 1,
                type: :answer,
                contents: [
                  %{sequence: 1, kind: :text, content_text: "Checking."},
                  %{
                    sequence: 2,
                    kind: :opaque,
                    content_json: %{
                      "responses_item" => %{
                        "type" => "message",
                        "role" => "assistant",
                        "status" => "completed",
                        "phase" => "commentary",
                        "content" => [
                          %{
                            "type" => "output_text",
                            "text" => "Checking.",
                            "annotations" => []
                          }
                        ]
                      }
                    }
                  }
                ]
              },
              %{
                sequence: 2,
                type: :answer,
                contents: [
                  %{sequence: 1, kind: :text, content_text: "Done."},
                  %{
                    sequence: 2,
                    kind: :opaque,
                    content_json: %{
                      "responses_item" => %{
                        "type" => "message",
                        "role" => "assistant",
                        "status" => "completed",
                        "phase" => "final_answer",
                        "content" => [
                          %{
                            "type" => "output_text",
                            "text" => "Done.",
                            "annotations" => []
                          }
                        ]
                      }
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    assert History.build_responses_input_items(history) == [
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "commentary",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Checking.",
                   "annotations" => []
                 }
               ]
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "final_answer",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Done.",
                   "annotations" => []
                 }
               ]
             }
           ]
  end

  test "drops orphaned responses tool calls without matching tool outputs" do
    history = [
      %{
        role: :assistant,
        steps: [
          %{
            sequence: 1,
            items: [
              %{
                sequence: 1,
                type: :answer,
                contents: [
                  %{sequence: 1, kind: :text, content_text: "Checking."},
                  %{
                    sequence: 2,
                    kind: :opaque,
                    content_json: %{
                      "responses_item" => %{
                        "type" => "message",
                        "role" => "assistant",
                        "status" => "completed",
                        "phase" => "commentary",
                        "content" => [
                          %{
                            "type" => "output_text",
                            "text" => "Checking.",
                            "annotations" => []
                          }
                        ]
                      }
                    }
                  }
                ]
              },
              %{
                sequence: 2,
                type: :tool_call,
                contents: [
                  %{
                    sequence: 1,
                    kind: :opaque,
                    content_json: %{
                      "type" => "function_call",
                      "id" => "fc_orphan",
                      "call_id" => "call_orphan",
                      "name" => "web__read_url",
                      "arguments" => ~s({"url":"https://example.com"})
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    assert History.build_responses_input_items(history) == [
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "commentary",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Checking.",
                   "annotations" => []
                 }
               ]
             }
           ]
  end
end
