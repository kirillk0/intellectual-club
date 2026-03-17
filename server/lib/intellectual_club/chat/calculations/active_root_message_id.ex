defmodule IntellectualClub.Chat.Calculations.ActiveRootMessageId do
  @moduledoc """
  Root message id of the currently active branch (`chat.last_message_id` chain).
  """

  use Ash.Resource.Calculation

  alias IntellectualClub.Chat.ChatMessage

  require Ash.Query

  @impl true
  def load(_query, _opts, _context), do: [:id, :last_message_id]

  @impl true
  def calculate(records, _opts, context) do
    actor = Map.get(context, :actor)

    chat_ids =
      records
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    parents_by_chat = load_parent_maps(chat_ids, actor)

    Enum.map(records, fn record ->
      chat_id = Map.get(record, :id)
      leaf_id = Map.get(record, :last_message_id)
      parents = Map.get(parents_by_chat, chat_id, %{})
      root_from_leaf(leaf_id, parents)
    end)
  end

  defp load_parent_maps([], _actor), do: %{}

  defp load_parent_maps(chat_ids, actor) when is_list(chat_ids) do
    ChatMessage
    |> Ash.Query.filter(chat_id in ^chat_ids)
    |> Ash.Query.select([:id, :chat_id, :parent_id])
    |> Ash.read!(actor: actor)
    |> Enum.reduce(%{}, fn message, acc ->
      Map.update(acc, message.chat_id, %{message.id => message.parent_id}, fn parent_map ->
        Map.put(parent_map, message.id, message.parent_id)
      end)
    end)
  end

  defp root_from_leaf(nil, _parents), do: nil

  defp root_from_leaf(leaf_id, parents) when is_integer(leaf_id) and is_map(parents) do
    do_root_from_leaf(leaf_id, parents, MapSet.new())
  end

  defp root_from_leaf(_leaf_id, _parents), do: nil

  defp do_root_from_leaf(message_id, parents, seen) do
    if MapSet.member?(seen, message_id) do
      message_id
    else
      next_seen = MapSet.put(seen, message_id)

      case Map.fetch(parents, message_id) do
        {:ok, nil} ->
          message_id

        {:ok, parent_id} when is_integer(parent_id) ->
          do_root_from_leaf(parent_id, parents, next_seen)

        {:ok, _other} ->
          message_id

        :error ->
          message_id
      end
    end
  end
end
