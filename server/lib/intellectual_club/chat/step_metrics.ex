defmodule IntellectualClub.Chat.StepMetrics do
  @moduledoc """
  Derived latency and throughput metrics for chat message steps.
  """

  @spec time_to_first_token_ms(DateTime.t() | nil, DateTime.t() | nil) :: integer() | nil
  def time_to_first_token_ms(%DateTime{} = started_at, %DateTime{} = first_token_at) do
    case DateTime.diff(first_token_at, started_at, :microsecond) do
      diff_us when diff_us >= 0 -> div(diff_us, 1_000)
      _other -> nil
    end
  end

  def time_to_first_token_ms(_started_at, _first_token_at), do: nil

  @spec tokens_per_second(integer() | nil, DateTime.t() | nil, DateTime.t() | nil) ::
          float() | nil
  def tokens_per_second(output_tokens, %DateTime{} = first_token_at, %DateTime{} = finished_at)
      when is_integer(output_tokens) and output_tokens >= 0 do
    case DateTime.diff(finished_at, first_token_at, :microsecond) do
      diff_us when diff_us > 0 ->
        output_tokens / (diff_us / 1_000_000)

      _other ->
        nil
    end
  end

  def tokens_per_second(_output_tokens, _first_token_at, _finished_at), do: nil
end
