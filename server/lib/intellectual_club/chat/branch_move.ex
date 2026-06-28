defmodule IntellectualClub.Chat.BranchMove do
  @moduledoc """
  Moves a message branch into a new chat while copying its ancestor prefix.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatSettingsCopy
  alias IntellectualClub.Chat.Continuation
  alias IntellectualClub.Chat.MessageTreeCopy
  alias IntellectualClub.Repo
  alias IntellectualClub.Llm.LlmUsageRecord

  require Ash.Query

  @type move_result :: %{
          chat: Chat.t()
        }

  @spec move_branch_to_new_chat(Chat.t() | integer(), integer(), map()) ::
          {:ok, move_result()} | {:error, term()}
  def move_branch_to_new_chat(source_chat_or_id, message_id, actor)
      when is_integer(message_id) do
    with {:ok, %Chat{} = source} <- fetch_source_chat(source_chat_or_id, actor),
         messages <- load_messages(source.id, actor),
         {:ok, context} <- build_move_context(source, messages, message_id) do
      Repo.transaction(fn -> perform_move!(context, actor) end)
      |> unwrap_transaction()
    end
  end

  def move_branch_to_new_chat(_source_chat_or_id, _message_id, _actor),
    do: {:error, :message_required}

  defp fetch_source_chat(%Chat{id: id}, actor) when is_integer(id),
    do: Ash.get(Chat, id, actor: actor)

  defp fetch_source_chat(chat_id, actor) when is_integer(chat_id),
    do: Ash.get(Chat, chat_id, actor: actor)

  defp fetch_source_chat(_source_chat_or_id, _actor), do: {:error, :invalid_chat_id}

  defp load_messages(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(created_at: :asc, id: :asc)
    |> Ash.read!(actor: actor)
  end

  defp build_move_context(%Chat{} = source, messages, message_id) do
    by_id = Map.new(messages, &{&1.id, &1})
    children = build_children_index(messages)

    with {:ok, selected} <- fetch_message_from_chat(by_id, message_id),
         :ok <- ensure_has_siblings(selected, children),
         moved_messages = subtree_messages(selected, children),
         :ok <- ensure_not_generating(moved_messages) do
      moved_ids = MapSet.new(moved_messages, & &1.id)
      prefix_ids = chain_ids(selected.parent_id, parents_by_id(messages))
      prefix_messages = Enum.map(prefix_ids, &Map.fetch!(by_id, &1))
      source_last_in_moved? = MapSet.member?(moved_ids, source.last_message_id)

      {:ok,
       %{
         source: source,
         selected: selected,
         children: children,
         moved_messages: moved_messages,
         moved_ids: moved_ids,
         prefix_messages: prefix_messages,
         source_last_in_moved?: source_last_in_moved?,
         source_last_id: source.last_message_id,
         target_last_id:
           if(source_last_in_moved?,
             do: source.last_message_id,
             else: selected |> rightmost_leaf(children) |> Map.get(:id)
           ),
         source_replacement_last_id:
           if(source_last_in_moved?,
             do: replacement_source_last_id(selected, children),
             else: nil
           )
       }}
    end
  end

  defp fetch_message_from_chat(by_id, message_id) do
    case Map.get(by_id, message_id) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  end

  defp ensure_has_siblings(%ChatMessage{} = selected, children) do
    siblings = Map.get(children, selected.parent_id, [])

    if length(siblings) > 1 do
      :ok
    else
      {:error, :no_siblings}
    end
  end

  defp ensure_not_generating(messages) when is_list(messages) do
    if Enum.any?(messages, &(Map.get(&1, :status) in [:generating, "generating"])) do
      {:error, :branch_has_generating_message}
    else
      :ok
    end
  end

  defp perform_move!(context, actor) do
    target = create_target_chat!(context.source, actor)
    ChatSettingsCopy.copy_bindings!(context.source.id, target.id, actor)

    if context.source_last_in_moved? do
      set_chat_last_message!(context.source, context.source_replacement_last_id, actor)
    end

    copied_prefix_ids =
      context.prefix_messages
      |> Ash.load!(MessageTreeCopy.load_spec(), actor: actor, strict?: true)
      |> MessageTreeCopy.copy_messages!(target, actor)

    moved_root_parent_id = mapped_prefix_parent_id(context.selected.parent_id, copied_prefix_ids)

    context.moved_messages
    |> Enum.each(fn message ->
      parent_id =
        if message.id == context.selected.id do
          moved_root_parent_id
        else
          message.parent_id
        end

      move_message_to_chat!(message, target.id, parent_id, actor)
    end)

    set_chat_last_message!(target, context.target_last_id, actor)
    update_child_chat_parents!(context.source.id, target.id, context.moved_ids, actor)
    update_usage_records!(context.moved_messages, target.id, actor)

    %{chat: Ash.get!(Chat, target.id, actor: actor, load: [:last_message])}
  end

  defp create_target_chat!(%Chat{} = source, actor) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, Continuation.branch_target_attrs(source),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp mapped_prefix_parent_id(nil, _copied_prefix_ids), do: nil

  defp mapped_prefix_parent_id(parent_id, copied_prefix_ids) when is_integer(parent_id) do
    Map.fetch!(copied_prefix_ids, parent_id)
  end

  defp move_message_to_chat!(%ChatMessage{} = message, target_chat_id, parent_id, actor) do
    message
    |> Ash.Changeset.for_update(
      :move_to_chat,
      %{chat_id: target_chat_id, parent_id: parent_id},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp set_chat_last_message!(%Chat{} = chat, last_message_id, actor) do
    chat
    |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: last_message_id},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp update_child_chat_parents!(source_chat_id, target_chat_id, moved_ids, actor) do
    moved_id_list = MapSet.to_list(moved_ids)

    if moved_id_list == [] do
      :ok
    else
      Chat
      |> Ash.Query.filter(
        parent_chat_id == ^source_chat_id and parent_message_id in ^moved_id_list
      )
      |> Ash.read!(actor: actor)
      |> Enum.each(fn child ->
        child
        |> Ash.Changeset.for_update(:update, %{parent_chat_id: target_chat_id}, actor: actor)
        |> Ash.update!(actor: actor)
      end)
    end
  end

  defp update_usage_records!(moved_messages, target_chat_id, actor) do
    message_ids = Enum.map(moved_messages, & &1.id)

    if message_ids == [] do
      :ok
    else
      step_ids =
        ChatMessageStep
        |> Ash.Query.filter(chat_message_id in ^message_ids)
        |> Ash.Query.select([:id])
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.id)

      if step_ids == [] do
        :ok
      else
        LlmUsageRecord
        |> Ash.Query.filter(chat_message_step_id in ^step_ids)
        |> Ash.read!(actor: actor)
        |> Enum.each(fn record ->
          record
          |> Ash.Changeset.for_update(:update, %{chat_id: target_chat_id}, actor: actor)
          |> Ash.update!(actor: actor)
        end)
      end
    end
  end

  defp replacement_source_last_id(%ChatMessage{} = selected, children) do
    children
    |> Map.get(selected.parent_id, [])
    |> Enum.reject(&(&1.id == selected.id))
    |> List.last()
    |> rightmost_leaf(children)
    |> Map.get(:id)
  end

  defp subtree_messages(%ChatMessage{} = root, children) do
    do_subtree_messages(root, children, [])
    |> Enum.reverse()
  end

  defp do_subtree_messages(%ChatMessage{} = message, children, acc) do
    children
    |> Map.get(message.id, [])
    |> Enum.reduce([message | acc], fn child, acc ->
      do_subtree_messages(child, children, acc)
    end)
  end

  defp build_children_index(messages) do
    messages
    |> Enum.reduce(%{}, fn message, acc ->
      Map.update(acc, message.parent_id, [message], &[message | &1])
    end)
    |> Enum.into(%{}, fn {parent_id, children} ->
      {parent_id, Enum.sort_by(children, &sort_key/1)}
    end)
  end

  defp parents_by_id(messages) do
    Map.new(messages, &{&1.id, &1.parent_id})
  end

  defp chain_ids(nil, _parents), do: []

  defp chain_ids(leaf_id, parents) when is_integer(leaf_id) and is_map(parents) do
    do_chain_ids(leaf_id, parents, MapSet.new(), [])
  end

  defp do_chain_ids(nil, _parents, _seen, acc), do: acc

  defp do_chain_ids(node_id, parents, seen, acc) do
    if MapSet.member?(seen, node_id) do
      acc
    else
      next_seen = MapSet.put(seen, node_id)
      do_chain_ids(Map.get(parents, node_id), parents, next_seen, [node_id | acc])
    end
  end

  defp rightmost_leaf(%ChatMessage{} = node, children) do
    case Map.get(children, node.id, []) do
      [] -> node
      node_children -> node_children |> List.last() |> rightmost_leaf(children)
    end
  end

  defp sort_key(message) do
    {sort_timestamp(message.created_at), message.id || 0}
  end

  defp sort_timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp sort_timestamp(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp sort_timestamp(_value), do: -1

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
