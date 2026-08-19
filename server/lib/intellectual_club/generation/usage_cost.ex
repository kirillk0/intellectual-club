defmodule IntellectualClub.Generation.UsageCost do
  @moduledoc """
  Resolves a provider-reported or manually calculated cost for canonical usage.
  """

  @million_tokens 1_000_000

  @spec resolve(map(), map()) :: float() | nil
  def resolve(usage, pricing) when is_map(usage) and is_map(pricing) do
    case non_negative_number(usage_value(usage, :cost)) do
      {:ok, provider_cost} -> provider_cost
      :error -> calculate_manual_cost(usage, pricing)
    end
  end

  def resolve(_usage, _pricing), do: nil

  defp calculate_manual_cost(usage, pricing) do
    with {:ok, cold_input_price} <-
           non_negative_number(Map.get(pricing, :cold_input_price_per_million_tokens)),
         {:ok, cached_input_price} <-
           non_negative_number(Map.get(pricing, :cached_input_price_per_million_tokens)),
         {:ok, output_price} <-
           non_negative_number(Map.get(pricing, :output_price_per_million_tokens)),
         {:ok, input_tokens} <- non_negative_integer(usage_value(usage, :input_tokens)),
         {:ok, output_tokens} <- non_negative_integer(usage_value(usage, :output_tokens)),
         {:ok, cached_input_tokens} <- cached_input_tokens(usage, input_tokens) do
      cold_input_tokens = input_tokens - cached_input_tokens

      (cold_input_tokens * cold_input_price +
         cached_input_tokens * cached_input_price + output_tokens * output_price) /
        @million_tokens
    else
      _error -> nil
    end
  end

  defp cached_input_tokens(usage, input_tokens) do
    case usage_value(usage, :cached_input_tokens) do
      nil ->
        {:ok, 0}

      value when is_integer(value) ->
        {:ok, value |> max(0) |> min(input_tokens)}

      _other ->
        :error
    end
  end

  defp usage_value(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, value} -> value
      :error -> Map.get(usage, Atom.to_string(key))
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value), do: :error

  defp non_negative_number(value) when is_integer(value) and value >= 0,
    do: {:ok, value * 1.0}

  defp non_negative_number(value) when is_float(value) and value >= 0.0,
    do: {:ok, value}

  defp non_negative_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0.0 -> {:ok, parsed}
      _other -> :error
    end
  end

  defp non_negative_number(_value), do: :error
end
