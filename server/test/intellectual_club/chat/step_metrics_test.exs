defmodule IntellectualClub.Chat.StepMetricsTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Chat.StepMetrics

  test "tokens per second excludes first-token latency and the first token" do
    first_token_at = ~U[2026-04-16 10:00:00.250000Z]
    last_token_at = ~U[2026-04-16 10:00:02.250000Z]

    assert_in_delta StepMetrics.tokens_per_second(21, first_token_at, last_token_at), 10.0, 0.0001
  end

  test "tokens per second requires a measurable streamed interval" do
    token_at = ~U[2026-04-16 10:00:00.250000Z]

    assert StepMetrics.tokens_per_second(1, token_at, token_at) == nil
    assert StepMetrics.tokens_per_second(20, token_at, token_at) == nil
    assert StepMetrics.tokens_per_second(20, token_at, nil) == nil
  end
end
