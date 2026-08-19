defmodule IntellectualClub.Llm.Validations.CompleteManualPricing do
  @moduledoc """
  Requires manual LLM pricing to be either fully configured or fully unset.
  """

  use Ash.Resource.Validation

  @pricing_fields [
    :cold_input_price_per_million_tokens,
    :cached_input_price_per_million_tokens,
    :output_price_per_million_tokens
  ]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    configured_count =
      Enum.count(@pricing_fields, fn field ->
        not is_nil(Ash.Changeset.get_attribute(changeset, field))
      end)

    if configured_count in [0, length(@pricing_fields)] do
      :ok
    else
      {:error,
       field: :cold_input_price_per_million_tokens,
       message: "manual pricing must include cold input, cached input, and output prices"}
    end
  end
end
