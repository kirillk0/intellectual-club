defmodule IntellectualClub.Generation.HistoryTest do
  @moduledoc """
  Canonical history handling in `IntellectualClub.Generation.History`: role
  boundary repair, trace projection helpers, history modes and the replay of
  reasoning captured by the provider stream reducers.
  """

  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.{History, RuntimeTrace}
  alias IntellectualClub.Llm.Providers

  @placeholder "<There is no user message yet, you should write first>"

  @blank_trace_user %{
    role: :user,
    steps: [
      %{
        sequence: 1,
        items: [
          %{
            sequence: 1,
            type: :input,
            contents: [%{sequence: 1, kind: :text, content_text: " \n\t "}]
          }
        ]
      }
    ]
  }

  @media_user %{
    role: :user,
    steps: [
      %{
        sequence: 1,
        items: [
          %{
            sequence: 1,
            type: :input,
            contents: [%{sequence: 1, kind: :media, external_id: "media-id"}]
          }
        ]
      }
    ]
  }

  @reasoning %{
    "type" => "reasoning",
    "id" => "rs_old",
    "summary" => [],
    "encrypted_content" => "reusable-secret"
  }

  describe "fix_role_alteration/1" do
    for {name, history, expected} <- [
          {"wraps assistant-only history in placeholders without merging messages",
           [%{role: :assistant, content: "First"}, %{role: :assistant, content: "Second"}],
           [
             %{role: :user, content: @placeholder},
             %{role: :assistant, content: "First"},
             %{role: :assistant, content: "Second"},
             %{role: :user, content: @placeholder}
           ]},
          {"keeps adjacent user messages separate",
           [%{role: :user, content: "First"}, %{role: :user, content: "Second"}],
           [%{role: :user, content: "First"}, %{role: :user, content: "Second"}]},
          {"replaces empty legacy and trace user messages",
           [
             %{role: :user, content: "  "},
             %{role: :assistant, content: "Answer"},
             @blank_trace_user
           ],
           [
             %{role: :user, content: @placeholder},
             %{role: :assistant, content: "Answer"},
             %{role: :user, content: @placeholder}
           ]},
          {"keeps a user message that contains canonical media", [@media_user], [@media_user]},
          {"creates one placeholder for an empty history", [],
           [%{role: :user, content: @placeholder}]}
        ] do
      test name do
        assert History.fix_role_alteration(unquote(Macro.escape(history))) ==
                 unquote(Macro.escape(expected))
      end
    end
  end

  describe "trace projection helpers" do
    test "normalizes legacy messages without provider projection" do
      assert History.normalize_message(%{role: :user, content: "Hello"}) == %{
               "role" => "user",
               "content" => "Hello"
             }

      assert History.normalize_message(%{
               "role" => "assistant",
               "content" => [%{"type" => "text"}]
             }) ==
               %{"role" => "assistant", "content" => [%{"type" => "text"}]}

      assert History.normalize_message(%{role: "user", content: "Wrong boundary"}) == nil
      assert History.normalize_message(%{role: :system, content: "Ignored"}) == nil
    end

    test "extracts ordered trace text and opaque payloads" do
      message = %{
        role: :assistant,
        steps: [
          %{
            sequence: 2,
            items: [
              %{
                sequence: 1,
                type: :answer,
                contents: [
                  %{sequence: 2, kind: :text, content_text: "second"},
                  %{sequence: 1, kind: :text, content_text: "first-"}
                ]
              }
            ]
          },
          %{
            sequence: 1,
            items: [
              %{
                sequence: 1,
                type: :tool_call,
                contents: [
                  %{sequence: 1, kind: :opaque, content_json: %{"name" => "tool"}}
                ]
              }
            ]
          }
        ]
      }

      assert History.trace_message?(message)
      assert History.message_role(message) == "assistant"
      assert History.project_text_for_item_type(message, :answer) == "first-second"

      [tool_item] =
        message
        |> History.steps()
        |> Enum.sort_by(&History.sort_seq/1)
        |> hd()
        |> History.items()

      assert History.item_type(tool_item) == :tool_call
      assert History.opaque_payloads(tool_item) == [%{"name" => "tool"}]
    end

    test "trace helpers consume canonical atom-valued domain maps" do
      assert History.item_type(:error) == :error
      assert History.item_type(:other) == :other
      assert History.item_type(%{type: "answer"}) == :other

      assert History.content_kind(:media) == :media
      assert History.content_kind(%{kind: "text"}) == :other

      refute History.trace_message?(%{"steps" => []})
      assert History.message_role(%{"role" => "assistant"}) == nil
    end
  end

  describe "for_mode/3" do
    test "every adapter replays only eligible opaque reasoning and keeps canonical answers" do
      adapters = [
        {Providers.Responses, @reasoning},
        {Providers.ResponsesWss, @reasoning},
        {Providers.GoogleInteractions,
         %{"google_interaction_step" => %{"type" => "thought", "signature" => "reusable-secret"}}},
        {Providers.AnthropicMessages,
         %{
           "anthropic_content_block" => %{
             "type" => "thinking",
             "thinking" => "Native thinking",
             "signature" => "reusable-secret"
           }
         }},
        {Providers.OpenRouterChatCompletion,
         %{
           "chat_completion_reasoning" => %{
             "reasoning_details" => [
               %{"type" => "reasoning.encrypted", "data" => "reusable-secret", "index" => 0}
             ]
           }
         }},
        {Providers.NvidiaBuildChatCompletion,
         %{"chat_completion_reasoning" => %{"reasoning_content" => "reusable-secret"}}}
      ]

      for {adapter, opaque} <- adapters,
          {mode, configuration_id, reasoning?, tools?} <- [
            {:agent, 4, false, true},
            {:chat, 4, false, false},
            {:full, 4, true, true},
            {:full, 5, false, true},
            {:full, nil, false, true}
          ] do
        history = fixture(opaque) |> History.for_mode(mode, configuration_id)

        result =
          adapter.build_initial_request(%{
            history: history,
            model_name: "test-model",
            parameters: %{},
            tools: [],
            system_prompt: ""
          })

        input = Jason.encode!(result.request_snapshot.model_input)
        assert String.contains?(input, "reusable-secret") == reasoning?, inspect({adapter, mode})
        assert String.contains?(input, "tool-return-value") == tools?, inspect({adapter, mode})
        assert String.contains?(input, "Edited answer")
        assert String.contains?(input, "User steering")
        assert String.contains?(input, "turn_aborted") == (mode != :chat)
        refute String.contains?(input, "stale-raw-response")
        refute String.contains?(input, "display-only-reasoning")
      end
    end

    test "full mode selects reasoning per message and never treats missing configuration IDs as compatible" do
      message = Enum.at(fixture(@reasoning), 1)
      history = Enum.map([4, 5, 4, nil], &Map.put(message, :llm_configuration_id, &1))

      for {id, expected} <- [
            {4, [true, false, true, false]},
            {5, [false, true, false, false]},
            {nil, [false, false, false, false]}
          ] do
        actual =
          history
          |> History.for_mode(:full, id)
          |> Enum.map(fn entry ->
            entry.steps |> Enum.flat_map(& &1.items) |> Enum.any?(&(&1.type == :reasoning))
          end)

        assert actual == expected
      end
    end

    test "full mode omits text-only reasoning even if the raw response has reusable data" do
      history = fixture(nil) |> History.for_mode(:full, 4)
      input = Providers.Responses.build_initial_request(%{history: history}).raw_request
      refute inspect(input) =~ "display-only-reasoning"
      refute inspect(input) =~ "stale-raw-response"
      refute Enum.any?(input["input"], &(&1["type"] == "reasoning"))
    end

    test "chat mode removes empty assistant turns before role repair and keeps user media" do
      user = %{
        role: :user,
        steps: [
          %{
            items: [
              item(:input, 1, "", nil)
              |> Map.put(
                :contents,
                [%{kind: :media, sequence: 1, file_id: 12}]
              )
            ]
          }
        ]
      }

      assistant = %{
        role: :assistant,
        steps: [%{items: [item(:reasoning, 1, "Hidden", @reasoning)]}]
      }

      assert [^user] =
               [user, assistant] |> History.for_mode(:chat, 4) |> History.fix_role_alteration()
    end
  end

  describe "reasoning round trip through the provider stream reducers" do
    test "Responses HTTP and WSS replay terminal encrypted reasoning that has no text" do
      first = %{
        "id" => "rs_1",
        "type" => "reasoning",
        "summary" => [],
        "encrypted_content" => "encrypted-first"
      }

      second = %{
        "id" => "rs_2",
        "type" => "reasoning",
        "summary" => [],
        "encrypted_content" => "encrypted-second"
      }

      events = [
        %{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => Map.delete(first, "encrypted_content")
        },
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => first},
        %{
          "type" => "response.completed",
          "response" => %{"output" => [Map.delete(first, "encrypted_content"), second]}
        }
      ]

      stored = persist_events(Providers.Responses.StreamEvents, events)
      assert Enum.map(stored.items, & &1.type) == [:reasoning, :reasoning]

      assert Enum.all?(stored.items, fn item ->
               Enum.all?(item.contents, &(&1.kind == :opaque))
             end)

      for provider <- [Providers.Responses, Providers.ResponsesWss] do
        input =
          provider.build_initial_request(%{history: full_history(stored), model_name: "test"}).raw_request[
            "input"
          ]

        assert Enum.map(input, & &1["encrypted_content"]) == [
                 "encrypted-first",
                 "encrypted-second"
               ]
      end
    end

    test "Google Interactions replays signed thoughts, including a terminal-only block" do
      thought = %{
        "type" => "thought",
        "signature" => "signature-one",
        "summary" => [%{"type" => "text", "text" => "Summary"}]
      }

      hidden = %{"type" => "thought", "signature" => "signature-two"}

      events = [
        %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}},
        %{
          "event_type" => "step.delta",
          "index" => 0,
          "delta" => %{
            "type" => "thought_summary",
            "content" => %{"type" => "text", "text" => "Sum"}
          }
        },
        %{
          "event_type" => "step.delta",
          "index" => 0,
          "delta" => %{
            "type" => "thought_summary",
            "content" => %{"type" => "text", "text" => "mary"}
          }
        },
        %{
          "event_type" => "step.delta",
          "index" => 0,
          "delta" => %{"type" => "thought_signature", "signature" => "signature-one"}
        },
        %{"event_type" => "step.stop", "index" => 0},
        %{
          "event_type" => "interaction.completed",
          "interaction" => %{"status" => "completed", "steps" => [thought, hidden]}
        }
      ]

      stored = persist_events(Providers.GoogleInteractions.StreamEvents, events)
      assert Enum.map(stored.items, & &1.type) == [:reasoning, :reasoning]
      assert [%{kind: :opaque}] = List.last(stored.items).contents

      request =
        Providers.GoogleInteractions.build_initial_request(%{
          history: full_history(stored),
          model_name: "test"
        }).raw_request

      assert request["input"] == [thought, hidden]
    end
  end

  defp fixture(opaque) do
    [
      %{role: :user, content: "Question"},
      %{
        role: :assistant,
        llm_configuration_id: 4,
        steps: [
          %{
            sequence: 1,
            raw_response: %{"reasoning" => "stale-raw-response"},
            items: [
              item(:reasoning, 1, "display-only-reasoning", opaque),
              item(:answer, 2, "Edited answer", nil),
              item(:tool_call, 3, "", %{
                "name" => "lookup",
                "call_id" => "call_1",
                "arguments" => %{}
              }),
              item(:tool_result, 4, "tool-return-value", %{"call_id" => "call_1"}),
              item(:steering, 5, "User steering", nil)
            ]
          }
        ]
      },
      %{role: :user, history_marker: :turn_aborted, content: "<turn_aborted>"},
      %{role: :user, content: "Next question"}
    ]
  end

  defp item(type, sequence, text, opaque) do
    contents = [%{kind: :text, sequence: 1, content_text: text}]

    contents =
      if opaque,
        do: contents ++ [%{kind: :opaque, sequence: 10_000, content_json: opaque}],
        else: contents

    %{type: type, sequence: sequence, contents: contents}
  end

  defp full_history(stored) do
    History.for_mode(
      [%{role: :assistant, llm_configuration_id: 1, steps: [Map.delete(stored, :raw_response)]}],
      :full,
      1
    )
  end

  defp persist_events(reducer, events) do
    emit = fn event -> send(self(), {:event, event}) end
    Enum.reduce(events, reducer.new_state(), &reducer.handle_event(&2, &1, %{}, emit))
    collect(RuntimeTrace.new_step()) |> RuntimeTrace.persistable()
  end

  defp collect(step) do
    receive do
      {:event, {:trace, event}} -> collect(RuntimeTrace.apply_event(step, event))
      {:event, _event} -> collect(step)
    after
      0 -> step
    end
  end
end
