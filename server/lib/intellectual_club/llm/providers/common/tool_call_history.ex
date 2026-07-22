defmodule IntellectualClub.Llm.Providers.Common.ToolCallHistory do
  @moduledoc """
  Matches persisted tool calls with their historical tool results.
  """

  alias IntellectualClub.Generation.History

  @type result_refs :: %{item_ids: MapSet.t(), call_ids: MapSet.t()}

  @spec result_refs([term()], (term() -> term())) :: result_refs()
  def result_refs(items, result_call_id_fun)
      when is_list(items) and is_function(result_call_id_fun, 1) do
    Enum.reduce(items, empty_refs(), fn item, refs ->
      if History.item_type(item) == :tool_result do
        refs
        |> maybe_put_item_id(History.tool_call_item_id(item))
        |> maybe_put_call_id(result_call_id_fun.(item))
      else
        refs
      end
    end)
  end

  def result_refs(_items, _result_call_id_fun), do: empty_refs()

  @spec paired?(term(), term(), result_refs()) :: boolean()
  def paired?(item, call_id, %{item_ids: item_ids, call_ids: call_ids}) do
    item_id = History.item_id(item)
    call_id = normalize_call_id(call_id)

    (is_integer(item_id) and MapSet.member?(item_ids, item_id)) or
      (call_id != "" and MapSet.member?(call_ids, call_id))
  end

  def paired?(_item, _call_id, _refs), do: false

  defp empty_refs, do: %{item_ids: MapSet.new(), call_ids: MapSet.new()}

  defp maybe_put_item_id(refs, item_id) when is_integer(item_id) do
    Map.update!(refs, :item_ids, &MapSet.put(&1, item_id))
  end

  defp maybe_put_item_id(refs, _item_id), do: refs

  defp maybe_put_call_id(refs, call_id) do
    case normalize_call_id(call_id) do
      "" -> refs
      normalized -> Map.update!(refs, :call_ids, &MapSet.put(&1, normalized))
    end
  end

  defp normalize_call_id(call_id) do
    call_id
    |> to_string()
    |> String.trim()
  end
end
