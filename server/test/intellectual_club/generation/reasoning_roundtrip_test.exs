defmodule IntellectualClub.Generation.ReasoningRoundtripTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.{History, RuntimeTrace}
  alias IntellectualClub.Llm.Providers

  test "HTTP and WSS share the reducer that preserves terminal encrypted output without text" do
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
    assert Enum.all?(stored.items, fn item -> Enum.all?(item.contents, &(&1.kind == :opaque)) end)

    for provider <- [Providers.Responses, Providers.ResponsesWss] do
      input =
        provider.build_initial_request(%{history: full_history(stored), model_name: "test"}).raw_request[
          "input"
        ]

      assert Enum.map(input, & &1["encrypted_content"]) == ["encrypted-first", "encrypted-second"]
    end
  end

  test "Google stores signed thoughts separately from summaries, including a terminal-only block" do
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
