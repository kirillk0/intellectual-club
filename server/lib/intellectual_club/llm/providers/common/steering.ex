defmodule IntellectualClub.Llm.Providers.Common.Steering do
  @moduledoc false

  @doc "Projects steering into user history using the ordinary attachment pipeline."
  def history(items) do
    items
    |> List.wrap()
    |> Enum.map(&contents/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.map(fn contents ->
      %{
        role: :user,
        steps: [%{sequence: 1, items: [%{type: :input, sequence: 1, contents: contents}]}]
      }
    end)
  end

  def contents(item) do
    blocks = if is_map(item), do: item_contents(item), else: []

    if blocks == [] do
      item
      |> texts()
      |> Enum.with_index(1)
      |> Enum.map(fn {text, sequence} ->
        %{kind: :text, content_text: text, sequence: sequence}
      end)
    else
      Enum.filter(blocks, &(Map.get(&1, :kind) in [:text, :media]))
    end
  end

  def media_options(context, provider_type) do
    [
      supports_image_input: Map.get(context, :supports_image_input, false),
      provider_type: provider_type
    ]
  end

  def chat_messages(items, context, provider_type) do
    items
    |> history()
    |> IntellectualClub.Llm.Providers.Common.ChatHistory.build_messages(
      media_options(context, provider_type)
    )
  end

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
