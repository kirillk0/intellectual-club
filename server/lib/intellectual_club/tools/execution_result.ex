defmodule IntellectualClub.Tools.ExecutionResult do
  @moduledoc """
  Canonical result returned by tool drivers.

  Known attachment descriptor fields use atom keys. The result `raw` map, unknown
  attachment fields, and nested values are opaque and keep their original shape.
  """

  @attachment_fields [
    :file_id,
    :file_external_id,
    :filename,
    :mime_type,
    :size_bytes,
    :sha256,
    :is_image
  ]

  defstruct text: "", raw: %{}, media: [], artifacts: []

  @typedoc """
  Attachment descriptor whose known fields are normalized to atom keys.

  Drivers may retain provider-specific opaque fields alongside the canonical fields.
  """
  @type attachment_item :: map()

  @type t :: %__MODULE__{
          text: String.t(),
          raw: map(),
          media: list(attachment_item()),
          artifacts: list(attachment_item())
        }

  @spec normalize(any()) :: t()
  def normalize(%__MODULE__{} = result) do
    %__MODULE__{
      text: to_string(result.text || ""),
      raw: normalize_map(result.raw),
      media: normalize_attachment_items(result.media),
      artifacts: normalize_attachment_items(result.artifacts)
    }
  end

  def normalize({text, raw}) do
    %__MODULE__{text: to_string(text || ""), raw: normalize_map(raw), media: [], artifacts: []}
  end

  def normalize(%{} = map) do
    %__MODULE__{
      text: to_string(Map.get(map, :text, Map.get(map, "text", ""))),
      raw: normalize_map(Map.get(map, :raw, Map.get(map, "raw", %{}))),
      media: normalize_attachment_items(Map.get(map, :media, Map.get(map, "media", []))),
      artifacts:
        normalize_attachment_items(Map.get(map, :artifacts, Map.get(map, "artifacts", [])))
    }
  end

  def normalize(_other), do: %__MODULE__{}

  defp normalize_attachment_items(items) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_attachment_item/1)
  end

  defp normalize_attachment_items(_other), do: []

  defp normalize_attachment_item(item) do
    Enum.reduce(@attachment_fields, Map.new(item), fn field, normalized ->
      string_field = Atom.to_string(field)

      case fetch_preferred_field(item, field, string_field) do
        {:ok, value} ->
          normalized
          |> Map.delete(string_field)
          |> Map.put(field, value)

        :error ->
          normalized
      end
    end)
  end

  defp fetch_preferred_field(item, field, string_field) do
    case Map.fetch(item, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(item, string_field)
    end
  end

  defp normalize_map(%{} = map), do: Map.new(map)
  defp normalize_map(nil), do: %{}
  defp normalize_map(other), do: %{"raw" => other}
end
