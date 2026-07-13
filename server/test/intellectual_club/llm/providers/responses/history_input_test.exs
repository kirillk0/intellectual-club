defmodule IntellectualClub.Llm.Providers.Responses.HistoryInputTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.Responses.HistoryInput

  test "synthesizes commentary and final_answer phases for canonical assistant answers" do
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

    assert HistoryInput.build_input_items(history) == [
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

  test "ignores legacy response messages and derives answer text and phase from canonical history" do
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
                  %{sequence: 1, kind: :text, content_text: "Edited checking."},
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
                  %{sequence: 1, kind: :text, content_text: "Edited done."},
                  %{
                    sequence: 2,
                    kind: :opaque,
                    content_json: %{
                      "type" => "message",
                      "role" => "assistant",
                      "status" => "completed",
                      "phase" => "commentary",
                      "content" => [
                        %{
                          "type" => "output_text",
                          "text" => "Done.",
                          "annotations" => []
                        }
                      ]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    assert HistoryInput.build_input_items(history) == [
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "commentary",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Edited checking.",
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
                   "text" => "Edited done.",
                   "annotations" => []
                 }
               ]
             }
           ]
  end

  test "uses the last non-empty canonical answer as final_answer" do
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
                contents: [%{sequence: 1, kind: :text, content_text: "Visible answer."}]
              },
              %{
                sequence: 2,
                type: :answer,
                contents: [
                  %{sequence: 1, kind: :text, content_text: "  \n"},
                  %{
                    sequence: 2,
                    kind: :opaque,
                    content_json: %{
                      "type" => "message",
                      "role" => "assistant",
                      "phase" => "final_answer",
                      "content" => [
                        %{
                          "type" => "output_text",
                          "text" => "Stale answer.",
                          "annotations" => []
                        }
                      ]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    assert HistoryInput.build_input_items(history) == [
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "final_answer",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Visible answer.",
                   "annotations" => []
                 }
               ]
             }
           ]
  end

  test "drops assistant history when every canonical answer is empty" do
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
                  %{sequence: 1, kind: :text, content_text: "  \n"},
                  %{
                    sequence: 2,
                    kind: :opaque,
                    content_json: %{
                      "type" => "message",
                      "role" => "assistant",
                      "phase" => "final_answer",
                      "content" => [
                        %{
                          "type" => "output_text",
                          "text" => "Stale answer.",
                          "annotations" => []
                        }
                      ]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    assert HistoryInput.build_input_items(history) == []
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

    assert HistoryInput.build_input_items(history) == [
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "final_answer",
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
