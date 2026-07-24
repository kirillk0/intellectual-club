defmodule IntellectualClub.Llm.Providers.Responses.HistoryInputTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Files.File, as: StoredFile
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

  test "groups parallel tool-result media after every function output" do
    first_file_id = "11111111-1111-4111-8111-111111111111"
    second_file_id = "22222222-2222-4222-8222-222222222222"

    history = [
      %{
        role: :assistant,
        steps: [
          %{
            sequence: 1,
            items: [
              responses_call_item(101, 1, "call_1", "read_image"),
              responses_call_item(102, 2, "call_2", "run_command"),
              responses_call_item(103, 3, "call_3", "read_image"),
              responses_result_item(
                201,
                1_001,
                101,
                "call_1",
                response_media(41, first_file_id, "one.png")
              ),
              responses_result_item(202, 1_002, 102, "call_2", nil),
              %{id: 301, sequence: 1_003, type: :artifact, contents: []},
              responses_result_item(
                203,
                1_004,
                103,
                "call_3",
                response_media(42, second_file_id, "two.png")
              )
            ]
          }
        ]
      }
    ]

    items =
      HistoryInput.build_input_items(history,
        supports_image_input: true,
        provider_type: "responses"
      )

    assert Enum.map(items, & &1["type"]) == [
             "function_call",
             "function_call",
             "function_call",
             "function_call_output",
             "function_call_output",
             "function_call_output",
             "message"
           ]

    media_message = List.last(items)
    assert media_message["role"] == "user"

    image_file_ids =
      media_message["content"]
      |> Enum.filter(&(&1["type"] == "input_image"))
      |> Enum.map(
        &get_in(&1, [
          "image_url",
          "$intellectual_club_file",
          "source_file_external_id"
        ])
      )

    assert image_file_ids == [first_file_id, second_file_id]
  end

  defp responses_call_item(id, sequence, call_id, name) do
    %{
      id: id,
      sequence: sequence,
      type: :tool_call,
      contents: [
        %{
          sequence: 1,
          kind: :opaque,
          content_json: %{
            "type" => "function_call",
            "id" => "fc_#{id}",
            "call_id" => call_id,
            "name" => name,
            "arguments" => "{}"
          }
        }
      ]
    }
  end

  defp responses_result_item(id, sequence, tool_call_item_id, call_id, media) do
    contents = [
      %{sequence: 1, kind: :text, content_text: "done"},
      %{
        sequence: 10_000,
        kind: :opaque,
        content_json: %{
          "type" => "function_call_output",
          "id" => "fco_#{id}",
          "call_id" => call_id,
          "output" => "done"
        }
      }
    ]

    %{
      id: id,
      sequence: sequence,
      type: :tool_result,
      tool_call_item_id: tool_call_item_id,
      contents: if(media, do: contents ++ [media], else: contents)
    }
  end

  defp response_media(id, external_id, filename) do
    %{
      sequence: 2,
      kind: :media,
      external_id:
        "33333333-3333-4333-8333-#{id |> Integer.to_string() |> String.pad_leading(12, "0")}",
      file_id: id,
      file: %StoredFile{
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
