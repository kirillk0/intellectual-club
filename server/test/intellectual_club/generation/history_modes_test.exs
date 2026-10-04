defmodule IntellectualClub.Generation.HistoryModesTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.History
  alias IntellectualClub.Llm.Providers

  @reasoning %{
    "type" => "reasoning",
    "id" => "rs_old",
    "summary" => [],
    "encrypted_content" => "reusable-secret"
  }

  test "all adapters replay only eligible opaque reasoning and keep canonical answers" do
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

  test "A B A selects reasoning per message and never treats missing IDs as compatible" do
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

  test "full omits old text-only reasoning even if the raw response has reusable data" do
    history = fixture(nil) |> History.for_mode(:full, 4)
    input = Providers.Responses.build_initial_request(%{history: history}).raw_request
    refute inspect(input) =~ "display-only-reasoning"
    refute inspect(input) =~ "stale-raw-response"
    refute Enum.any?(input["input"], &(&1["type"] == "reasoning"))
  end

  test "chat removes empty assistant turns before role boundary repair and retains user media" do
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
end
