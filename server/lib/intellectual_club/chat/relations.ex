defmodule IntellectualClub.Chat.Relations do
  @moduledoc """
  Parent and handoff child relation loading for chats.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Fork
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Generation.History

  require Ash.Query

  @type relation_entry :: %{
          chat: Chat.t(),
          kind: atom() | nil,
          message_id: integer() | nil,
          parent_tool_call_item_id: integer() | nil,
          parent_step_id: integer() | nil,
          parent_step_sequence: integer() | nil,
          parent_item_sequence: integer() | nil,
          anchor_message_id: integer() | nil,
          anchor_tool_call_item_id: integer() | nil,
          anchor_step_id: integer() | nil,
          anchor_step_sequence: integer() | nil,
          anchor_item_sequence: integer() | nil
        }

  @type continuation_nav_entry :: %{
          chat: Chat.t(),
          label: String.t(),
          kind: atom() | nil,
          message_id: integer() | nil
        }

  @max_lineage_hops 100

  @spec lineage_root_id(Chat.t(), map()) :: integer() | nil
  def lineage_root_id(%Chat{id: id} = chat, actor) when is_integer(id) do
    do_lineage_root_id(chat, actor, MapSet.new(), 0)
  end

  def lineage_root_id(_chat, _actor), do: nil

  @spec relations(Chat.t(), list(map()), map()) :: map()
  def relations(%Chat{} = chat, messages, actor) when is_list(messages) do
    relations(chat, messages, actor, child_relation_chats(chat.id, actor))
  end

  @spec relations(Chat.t(), list(map()), map(), [Chat.t()]) :: map()
  def relations(%Chat{} = chat, messages, actor, children)
      when is_list(messages) and is_list(children) do
    active_message_ids = MapSet.new(messages, & &1.id)

    {children_by_message_id, children_without_message} =
      Enum.reduce(children, {%{}, []}, fn child, {by_message_id, without_message} ->
        entry = child_entry(child)
        message_id = child.parent_message_id

        if is_integer(message_id) and MapSet.member?(active_message_ids, message_id) do
          key = Integer.to_string(message_id)
          {Map.update(by_message_id, key, [entry], &[entry | &1]), without_message}
        else
          {by_message_id, [entry | without_message]}
        end
      end)

    children_by_message_id =
      Map.new(children_by_message_id, fn {message_id, entries} ->
        {message_id, Enum.reverse(entries)}
      end)

    %{
      parent: parent_relation(chat, messages, actor),
      children_by_message_id: children_by_message_id,
      children_without_message: Enum.reverse(children_without_message)
    }
  end

  @spec parent_relation(Chat.t(), list(map()), map()) :: relation_entry() | nil
  def parent_relation(%Chat{parent_chat_id: parent_chat_id} = chat, messages, actor)
      when is_integer(parent_chat_id) and is_list(messages) do
    Chat
    |> Ash.Query.filter(id == ^parent_chat_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(relation_load(), strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = parent]} ->
        parent_anchor = relation_anchor(chat.parent_tool_call_item_id, actor)

        anchor =
          if chat.parent_relation_kind == Fork.relation_kind() do
            local_fork_anchor(messages, actor)
          end

        relation_entry(parent, chat, parent_anchor, anchor)

      _other ->
        nil
    end
  end

  def parent_relation(_chat, _messages, _actor), do: nil

  @spec child_handoff_chats(integer(), map()) :: [Chat.t()]
  def child_handoff_chats(chat_id, actor) when is_integer(chat_id) do
    relation_kind = Handoff.relation_kind()

    Chat
    |> Ash.Query.filter(parent_chat_id == ^chat_id and parent_relation_kind == ^relation_kind)
    |> Ash.Query.sort(created_at: :asc, id: :asc)
    |> Ash.Query.load(relation_load(), strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, children} when is_list(children) -> children
      _other -> []
    end
  end

  def child_handoff_chats(_chat_id, _actor), do: []

  @spec child_relation_chats(integer(), map()) :: [Chat.t()]
  def child_relation_chats(chat_id, actor) when is_integer(chat_id) do
    relation_kinds = [Handoff.relation_kind(), Fork.relation_kind(), :spawn]

    Chat
    |> Ash.Query.filter(parent_chat_id == ^chat_id and parent_relation_kind in ^relation_kinds)
    |> Ash.Query.sort(created_at: :asc, id: :asc)
    |> Ash.Query.load(relation_load(), strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, children} when is_list(children) -> children
      _other -> []
    end
  end

  def child_relation_chats(_chat_id, _actor), do: []

  @spec continuation_nav(Chat.t(), map()) :: [continuation_nav_entry()]
  def continuation_nav(%Chat{} = chat, actor) do
    chat = fetch_relation_chat(chat.id, actor) || chat
    root = continuation_root(chat, actor, MapSet.new())

    entries =
      root
      |> continuation_nav_entries(actor, 1, "", MapSet.new())

    if length(entries) > 1, do: entries, else: []
  end

  def continuation_nav(_chat, _actor), do: []

  defp do_lineage_root_id(%Chat{id: id}, _actor, _visited, hops)
       when hops >= @max_lineage_hops do
    id
  end

  defp do_lineage_root_id(%Chat{id: id, parent_chat_id: parent_id}, actor, visited, hops)
       when is_integer(id) do
    cond do
      MapSet.member?(visited, id) ->
        id

      not is_integer(parent_id) ->
        id

      true ->
        case fetch_lineage_chat(parent_id, actor) do
          %Chat{} = parent ->
            do_lineage_root_id(parent, actor, MapSet.put(visited, id), hops + 1)

          nil ->
            id
        end
    end
  end

  defp continuation_root(%Chat{id: id} = chat, actor, visited) when is_integer(id) do
    if MapSet.member?(visited, id) do
      chat
    else
      continuation_root_from_parent(chat, actor, MapSet.put(visited, id))
    end
  end

  defp continuation_root(chat, _actor, _visited), do: chat

  defp continuation_root_from_parent(%Chat{parent_chat_id: parent_id} = chat, actor, visited)
       when is_integer(parent_id) do
    if handoff_child?(chat) do
      case fetch_relation_chat(parent_id, actor) do
        %Chat{} = parent -> continuation_root(parent, actor, visited)
        nil -> chat
      end
    else
      chat
    end
  end

  defp continuation_root_from_parent(chat, _actor, _visited), do: chat

  defp continuation_nav_entries(%Chat{id: id} = chat, actor, number, suffix, visited)
       when is_integer(id) do
    if MapSet.member?(visited, id) do
      []
    else
      next_visited = MapSet.put(visited, id)
      children = child_handoff_chats(id, actor)
      child_count = length(children)

      child_entries =
        children
        |> Enum.with_index()
        |> Enum.flat_map(fn {child, index} ->
          child_suffix =
            if child_count == 1 do
              suffix
            else
              suffix <> branch_suffix(index)
            end

          continuation_nav_entries(child, actor, number + 1, child_suffix, next_visited)
        end)

      [
        %{
          chat: chat,
          label: Integer.to_string(number) <> suffix,
          kind: chat.parent_relation_kind,
          message_id: chat.parent_message_id
        }
        | child_entries
      ]
    end
  end

  defp continuation_nav_entries(_chat, _actor, _number, _suffix, _visited), do: []

  defp fetch_relation_chat(chat_id, actor) when is_integer(chat_id) do
    Chat
    |> Ash.Query.filter(id == ^chat_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(relation_load(), strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> chat
      _other -> nil
    end
  end

  defp fetch_lineage_chat(chat_id, actor) when is_integer(chat_id) do
    Chat
    |> Ash.Query.filter(id == ^chat_id)
    |> Ash.Query.select([:id, :parent_chat_id])
    |> Ash.Query.limit(1)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> chat
      _other -> nil
    end
  end

  defp handoff_child?(%Chat{parent_relation_kind: :handoff}), do: true
  defp handoff_child?(%Chat{}), do: false

  defp branch_suffix(index) when is_integer(index) and index >= 0 do
    alpha_suffix(index + 1, "")
  end

  defp alpha_suffix(0, suffix), do: suffix

  defp alpha_suffix(value, suffix) when value > 0 do
    value = value - 1
    char = <<?a + rem(value, 26)>>
    alpha_suffix(div(value, 26), char <> suffix)
  end

  defp child_entry(%Chat{} = child) do
    parent_anchor = loaded_relation_anchor(child.parent_tool_call_item)
    relation_entry(child, child, parent_anchor, parent_anchor)
  end

  defp relation_entry(%Chat{} = chat, %Chat{} = relation_source, parent_anchor, anchor) do
    %{
      chat: chat,
      kind: relation_source.parent_relation_kind,
      message_id: relation_source.parent_message_id,
      parent_tool_call_item_id: relation_source.parent_tool_call_item_id,
      parent_step_id: anchor_value(parent_anchor, :step_id),
      parent_step_sequence: anchor_value(parent_anchor, :step_sequence),
      parent_item_sequence: anchor_value(parent_anchor, :item_sequence),
      anchor_message_id: anchor_value(anchor, :message_id),
      anchor_tool_call_item_id: anchor_value(anchor, :tool_call_item_id),
      anchor_step_id: anchor_value(anchor, :step_id),
      anchor_step_sequence: anchor_value(anchor, :step_sequence),
      anchor_item_sequence: anchor_value(anchor, :item_sequence)
    }
  end

  defp local_fork_anchor(messages, actor) when is_list(messages) do
    message_order =
      messages
      |> Enum.with_index()
      |> Map.new(fn {message, index} -> {message.id, index} end)

    message_ids = Map.keys(message_order)

    steps =
      if message_ids == [] do
        []
      else
        ChatMessageStep
        |> Ash.Query.filter(chat_message_id in ^message_ids)
        |> Ash.Query.select([:id, :chat_message_id, :sequence])
        |> Ash.read!(actor: actor)
      end

    steps_by_id = Map.new(steps, &{&1.id, &1})
    step_ids = Map.keys(steps_by_id)

    result =
      if step_ids == [] do
        nil
      else
        ChatMessageItem
        |> Ash.Query.filter(chat_message_step_id in ^step_ids and type == :tool_result)
        |> Ash.Query.select([
          :id,
          :chat_message_step_id,
          :sequence,
          :type,
          :tool_call_item_id
        ])
        |> Ash.Query.load(contents: [:sequence, :kind, :content_json])
        |> Ash.read!(actor: actor)
        |> Enum.filter(&fork_instruction_result?/1)
        |> Enum.max_by(
          &fork_result_position(&1, steps_by_id, message_order),
          fn -> nil end
        )
      end

    case result do
      %ChatMessageItem{tool_call_item_id: tool_call_item_id}
      when is_integer(tool_call_item_id) ->
        relation_anchor(tool_call_item_id, actor)

      _other ->
        nil
    end
  end

  defp fork_result_position(item, steps_by_id, message_order) do
    step = Map.get(steps_by_id, item.chat_message_step_id)

    {
      Map.get(message_order, step && step.chat_message_id, -1),
      (step && step.sequence) || 0,
      item.sequence || 0,
      item.id || 0
    }
  end

  defp fork_instruction_result?(%ChatMessageItem{} = item) do
    History.item_type(item) == :tool_result and
      is_integer(item.tool_call_item_id) and
      Enum.any?(History.opaque_payloads(item), &fork_instruction_payload?/1)
  end

  defp fork_instruction_result?(_item), do: false

  defp fork_instruction_payload?(payload) when is_map(payload) do
    instruction =
      case Map.get(payload, "raw") do
        raw when is_map(raw) -> Map.get(raw, "fork_instruction")
        _other -> nil
      end || Map.get(payload, "fork_instruction")

    is_map(instruction) and Map.get(instruction, "subagent") == true
  end

  defp fork_instruction_payload?(_payload), do: false

  defp relation_anchor(tool_call_item_id, actor) when is_integer(tool_call_item_id) do
    step_query = Ash.Query.select(ChatMessageStep, [:id, :chat_message_id, :sequence])

    ChatMessageItem
    |> Ash.Query.filter(id == ^tool_call_item_id and type == :tool_call)
    |> Ash.Query.select([:id, :chat_message_step_id, :sequence])
    |> Ash.Query.load(chat_message_step: step_query)
    |> Ash.Query.limit(1)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%ChatMessageItem{} = item]} -> loaded_relation_anchor(item)
      _other -> nil
    end
  end

  defp relation_anchor(_tool_call_item_id, _actor), do: nil

  defp loaded_relation_anchor(%ChatMessageItem{} = item) do
    case loaded_relation(item.chat_message_step) do
      %ChatMessageStep{} = step ->
        %{
          message_id: step.chat_message_id,
          tool_call_item_id: item.id,
          step_id: step.id,
          step_sequence: step.sequence,
          item_sequence: item.sequence
        }

      _other ->
        nil
    end
  end

  defp loaded_relation_anchor(_item), do: nil

  defp anchor_value(anchor, key) when is_map(anchor), do: Map.get(anchor, key)
  defp anchor_value(_anchor, _key), do: nil

  defp loaded_relation(%Ash.NotLoaded{}), do: nil
  defp loaded_relation(value), do: value

  defp relation_load do
    step_query = Ash.Query.select(ChatMessageStep, [:id, :chat_message_id, :sequence])

    item_query =
      ChatMessageItem
      |> Ash.Query.select([:id, :chat_message_step_id, :sequence])
      |> Ash.Query.load(chat_message_step: step_query)

    [:bot, :last_message, parent_tool_call_item: item_query]
  end
end
