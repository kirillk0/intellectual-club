defmodule IntellectualClub.Chat.SubchatCosts do
  @moduledoc """
  Aggregates durable provider costs for subchat trees by their source message.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Llm.LlmUsageRecord

  require Ash.Query

  @root_relation_kinds [:fork, :spawn]
  @descendant_relation_kinds [:handoff, :fork, :spawn]
  @max_descendant_chats 10_000

  @type summary :: %{
          costs_by_message_id: %{optional(integer()) => float()},
          revision: String.t()
        }

  @spec summary(integer(), map()) :: summary()
  def summary(root_chat_id, actor) when is_integer(root_chat_id) and is_map(actor) do
    roots = direct_subchat_roots(root_chat_id, actor)

    source_message_by_chat_id =
      roots
      |> Enum.take(@max_descendant_chats)
      |> Map.new(fn chat -> {chat.id, chat.parent_message_id} end)

    source_message_by_chat_id =
      expand_descendants(
        roots,
        source_message_by_chat_id,
        MapSet.new([root_chat_id | Map.keys(source_message_by_chat_id)]),
        actor
      )

    usage_records = usage_records(Map.keys(source_message_by_chat_id), actor)

    %{
      costs_by_message_id: costs_by_source_message(usage_records, source_message_by_chat_id),
      revision: usage_revision(usage_records)
    }
  end

  def summary(_root_chat_id, _actor), do: empty_summary()

  defp empty_summary do
    %{costs_by_message_id: %{}, revision: usage_revision([])}
  end

  defp direct_subchat_roots(root_chat_id, actor) do
    Chat
    |> Ash.Query.filter(
      parent_chat_id == ^root_chat_id and parent_relation_kind in ^@root_relation_kinds
    )
    |> Ash.Query.select([:id, :parent_chat_id, :parent_message_id])
    |> Ash.Query.sort(id: :asc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, chats} when is_list(chats) -> chats
      _other -> []
    end
  end

  defp expand_descendants([], source_message_by_chat_id, _visited, _actor),
    do: source_message_by_chat_id

  defp expand_descendants(_frontier, source_message_by_chat_id, _visited, _actor)
       when map_size(source_message_by_chat_id) >= @max_descendant_chats,
       do: source_message_by_chat_id

  defp expand_descendants(frontier, source_message_by_chat_id, visited, actor) do
    parent_ids = Enum.map(frontier, & &1.id)

    children =
      Chat
      |> Ash.Query.filter(
        parent_chat_id in ^parent_ids and parent_relation_kind in ^@descendant_relation_kinds
      )
      |> Ash.Query.select([:id, :parent_chat_id, :parent_message_id])
      |> Ash.Query.sort(id: :asc)
      |> Ash.read(actor: actor)
      |> case do
        {:ok, chats} when is_list(chats) -> chats
        _other -> []
      end

    remaining = @max_descendant_chats - map_size(source_message_by_chat_id)

    fresh_children =
      children
      |> Enum.reject(&MapSet.member?(visited, &1.id))
      |> Enum.take(remaining)
      |> Enum.filter(&is_integer(Map.get(source_message_by_chat_id, &1.parent_chat_id)))

    next_sources =
      Enum.reduce(fresh_children, source_message_by_chat_id, fn child, acc ->
        Map.put(acc, child.id, Map.fetch!(acc, child.parent_chat_id))
      end)

    next_visited = Enum.reduce(fresh_children, visited, &MapSet.put(&2, &1.id))
    expand_descendants(fresh_children, next_sources, next_visited, actor)
  end

  defp usage_records([], _actor), do: []

  defp usage_records(chat_ids, actor) do
    LlmUsageRecord
    |> Ash.Query.filter(chat_id in ^chat_ids)
    |> Ash.Query.select([:id, :chat_id, :cost])
    |> Ash.Query.sort(id: :asc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, records} when is_list(records) -> records
      _other -> []
    end
  end

  defp costs_by_source_message(usage_records, source_message_by_chat_id) do
    Enum.reduce(usage_records, %{}, fn record, acc ->
      with source_message_id when is_integer(source_message_id) <-
             Map.get(source_message_by_chat_id, record.chat_id),
           cost when is_number(cost) <- record.cost do
        Map.update(acc, source_message_id, cost * 1.0, &(&1 + cost))
      else
        _other -> acc
      end
    end)
  end

  defp usage_revision(records) do
    rows = Enum.map(records, &[&1.id, &1.chat_id, &1.cost])

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(rows))
    |> Base.url_encode64(padding: false)
  end
end
