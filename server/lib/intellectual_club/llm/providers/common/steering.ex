defmodule IntellectualClub.Llm.Providers.Common.Steering do
  @moduledoc false

  @spec texts(term()) :: [String.t()]
  def texts(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(&texts_from_item/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp texts_from_item(text) when is_binary(text), do: [text]

  defp texts_from_item(%{} = item) do
    direct_text = Map.get(item, :text) || Map.get(item, :content)

    cond do
      is_binary(direct_text) ->
        [direct_text]

      is_list(direct_text) ->
        Enum.flat_map(direct_text, &texts_from_content/1)

      true ->
        item
        |> item_contents()
        |> Enum.flat_map(&texts_from_content/1)
    end
  end

  defp texts_from_item(_item), do: []

  defp item_contents(%{} = item) do
    cond do
      is_list(Map.get(item, :contents)) ->
        Map.get(item, :contents)

      is_map(Map.get(item, :contents_by_sequence)) ->
        item
        |> Map.get(:contents_by_sequence)
        |> Map.values()
        |> Enum.sort_by(&content_sequence/1)

      true ->
        []
    end
  end

  defp texts_from_content(text) when is_binary(text), do: [text]

  defp texts_from_content(%{} = content) do
    kind = Map.get(content, :kind)
    text = Map.get(content, :content_text)

    if kind in [:text, nil] and is_binary(text), do: [text], else: []
  end

  defp texts_from_content(_content), do: []

  defp content_sequence(%{} = content) do
    Map.get(content, :sequence, 0)
  end

  defp content_sequence(_content), do: 0
end
