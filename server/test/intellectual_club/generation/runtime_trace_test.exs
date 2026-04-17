defmodule IntellectualClub.Generation.RuntimeTraceTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.RuntimeTrace

  test "first answer text event records first_token_at once" do
    step =
      RuntimeTrace.new_step(
        started_at: ~U[2026-04-16 10:00:00.000000Z],
        raw_request: %{"model" => "demo-model"}
      )

    step =
      RuntimeTrace.apply_event(step, {:append_text, "answer", :answer, 1, "Hello"})

    assert %DateTime{} = step.first_token_at

    first_token_at = step.first_token_at

    step =
      RuntimeTrace.apply_event(step, {:append_text, "answer", :answer, 1, " world"})

    assert step.first_token_at == first_token_at
  end

  test "non-answer text events do not record first_token_at" do
    step =
      RuntimeTrace.new_step(
        started_at: ~U[2026-04-16 10:00:00.000000Z],
        raw_request: %{"model" => "demo-model"}
      )
      |> RuntimeTrace.apply_event({:append_text, "reasoning", :reasoning, 1, "Thinking"})
      |> RuntimeTrace.apply_event({:set_text, "error", :error, 1, "Boom"})

    assert step.first_token_at == nil
  end
end
