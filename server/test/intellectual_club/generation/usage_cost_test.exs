defmodule IntellectualClub.Generation.UsageCostTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.UsageCost

  @pricing %{
    cold_input_price_per_million_tokens: 2.0,
    cached_input_price_per_million_tokens: 0.5,
    output_price_per_million_tokens: 8.0
  }

  test "uses valid provider cost before manual pricing" do
    usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000, cost: "0"}

    assert UsageCost.resolve(usage, @pricing) == 0.0
    assert UsageCost.resolve(%{cost: 1.25}, @pricing) == 1.25
  end

  test "prices cold input and output when no cache is read" do
    usage = %{input_tokens: 1_000_000, output_tokens: 250_000}

    assert UsageCost.resolve(usage, @pricing) == 4.0
    refute Map.has_key?(usage, :cost)
  end

  test "prices cache reads separately and leaves cache creation in cold input" do
    usage = %{
      input_tokens: 1_000_000,
      cached_input_tokens: 400_000,
      cache_creation_input_tokens: 300_000,
      cache_write_cost: 999.0,
      output_tokens: 250_000
    }

    assert UsageCost.resolve(usage, @pricing) == 3.4
  end

  test "clamps cached input tokens into the total input range" do
    assert UsageCost.resolve(
             %{input_tokens: 1_000_000, cached_input_tokens: -10, output_tokens: 0},
             @pricing
           ) == 2.0

    assert UsageCost.resolve(
             %{input_tokens: 1_000_000, cached_input_tokens: 2_000_000, output_tokens: 0},
             @pricing
           ) == 0.5
  end

  test "requires complete pricing and sufficient canonical usage" do
    partial_pricing = Map.put(@pricing, :output_price_per_million_tokens, nil)

    assert UsageCost.resolve(%{input_tokens: 10, output_tokens: 5}, partial_pricing) == nil
    assert UsageCost.resolve(%{input_tokens: 10}, @pricing) == nil
    assert UsageCost.resolve(%{output_tokens: 5}, @pricing) == nil

    assert UsageCost.resolve(
             %{input_tokens: 10, cached_input_tokens: "5", output_tokens: 5},
             @pricing
           ) == nil
  end

  test "ignores invalid provider cost and falls back to manual pricing" do
    usage = %{input_tokens: 1_000_000, output_tokens: 0, cost: "not-a-number"}

    assert UsageCost.resolve(usage, @pricing) == 2.0
  end
end
