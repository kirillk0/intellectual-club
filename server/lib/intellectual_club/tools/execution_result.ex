defmodule IntellectualClub.Tools.ExecutionResult do
  @moduledoc """
  Canonical result returned by tool drivers.
  """

  defstruct text: "", raw: %{}, media: [], artifacts: []

  @type t :: %__MODULE__{
          text: String.t(),
          raw: map(),
          media: list(map()),
          artifacts: list(map())
        }

  @spec normalize(any()) :: t()
  def normalize(%__MODULE__{} = result) do
    %__MODULE__{
      text: to_string(result.text || ""),
      raw: normalize_map(result.raw),
      media: normalize_items(result.media),
      artifacts: normalize_items(result.artifacts)
    }
  end

  def normalize({text, raw}) do
    %__MODULE__{text: to_string(text || ""), raw: normalize_map(raw), media: [], artifacts: []}
  end

  def normalize(%{} = map) do
    %__MODULE__{
      text: to_string(Map.get(map, :text, Map.get(map, "text", ""))),
      raw: normalize_map(Map.get(map, :raw, Map.get(map, "raw", %{}))),
      media: normalize_items(Map.get(map, :media, Map.get(map, "media", []))),
      artifacts: normalize_items(Map.get(map, :artifacts, Map.get(map, "artifacts", [])))
    }
  end

  def normalize(_other), do: %__MODULE__{}

  defp normalize_items(items) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.new/1)
  end

  defp normalize_items(_other), do: []

  defp normalize_map(%{} = map), do: Map.new(map)
  defp normalize_map(nil), do: %{}
  defp normalize_map(other), do: %{"raw" => other}
end
