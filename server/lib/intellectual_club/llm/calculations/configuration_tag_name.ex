defmodule IntellectualClub.Llm.Calculations.ConfigurationTagName do
  @moduledoc """
  Exposes attached configuration tag names through parent-owned join resources.
  """

  use Ash.Resource.Calculation

  alias IntellectualClub.Llm.LlmConfigurationTag

  require Ash.Query

  @impl true
  def load(_query, _opts, _context), do: [:llm_configuration_tag_id]

  @impl true
  def calculate(records, _opts, _context) do
    names_by_id =
      records
      |> Enum.map(&Map.get(&1, :llm_configuration_tag_id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> load_names_by_id()

    Enum.map(records, fn record ->
      record
      |> Map.get(:llm_configuration_tag_id)
      |> then(&Map.get(names_by_id, &1))
    end)
  end

  defp load_names_by_id([]), do: %{}

  defp load_names_by_id(tag_ids) do
    LlmConfigurationTag
    |> Ash.Query.filter(id in ^tag_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, &1.name})
  end
end
