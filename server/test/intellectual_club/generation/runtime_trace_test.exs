defmodule IntellectualClub.Generation.RuntimeTraceTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.RuntimeTrace

  test "first provider output records token boundaries regardless of item type" do
    step =
      RuntimeTrace.new_step(
        started_at: ~U[2026-04-16 10:00:00.000000Z],
        raw_request: %{"model" => "demo-model"}
      )

    step =
      RuntimeTrace.apply_event(step, {:append_text, "reasoning", :reasoning, 1, "Thinking"})

    assert %DateTime{} = step.first_token_at
    assert step.last_token_at == step.first_token_at

    first_token_at = ~U[2000-01-01 00:00:00.000000Z]
    last_token_at = ~U[2000-01-01 00:00:01.000000Z]

    step =
      RuntimeTrace.new_step(first_token_at: first_token_at, last_token_at: last_token_at)
      |> RuntimeTrace.apply_event({:set_text, "tool-call", :tool_call, 1, "{\"query\":"})

    assert step.first_token_at == first_token_at
    assert DateTime.compare(step.last_token_at, last_token_at) == :gt
  end

  test "non-provider text events do not record token boundaries" do
    step =
      RuntimeTrace.new_step(
        started_at: ~U[2026-04-16 10:00:00.000000Z],
        raw_request: %{"model" => "demo-model"}
      )
      |> RuntimeTrace.apply_event({:append_text, "tool-result", :tool_result, 1, "Result"})
      |> RuntimeTrace.apply_event({:set_text, "error", :error, 1, "Boom"})

    assert step.first_token_at == nil
    assert step.last_token_at == nil
  end

  test "repeated text snapshots do not extend the output interval" do
    step =
      RuntimeTrace.new_step()
      |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Hello"})

    last_token_at = step.last_token_at

    step = RuntimeTrace.apply_event(step, {:set_text, "answer", :answer, 1, "Hello"})

    assert step.last_token_at == last_token_at
  end

  test "opaque reasoning and tool-call output records token boundaries" do
    step =
      RuntimeTrace.new_step()
      |> RuntimeTrace.apply_event(
        {:set_opaque, "reasoning", :reasoning, 10_000, %{"encrypted" => "payload"}}
      )

    assert %DateTime{} = step.first_token_at
    assert step.last_token_at == step.first_token_at
  end

  test "keeps domain atoms in persistable data and stringifies only the UI snapshot" do
    step =
      RuntimeTrace.new_step(status: :waiting_provider)
      |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Hello"})

    assert %{status: :waiting_provider, items: [%{type: :answer, contents: [content]}]} =
             RuntimeTrace.persistable(step)

    assert content.kind == :text

    assert %{status: "waiting_provider", items: [%{type: "answer", contents: [snapshot_content]}]} =
             RuntimeTrace.snapshot(step)

    assert snapshot_content.kind == "text"
  end
end
