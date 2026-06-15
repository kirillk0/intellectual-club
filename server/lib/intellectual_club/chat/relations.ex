defmodule IntellectualClub.Chat.Relations do
  @moduledoc """
  Parent and handoff child relation loading for chats.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Handoff

  require Ash.Query

  @type relation_entry :: %{
          chat: Chat.t(),
          kind: atom() | String.t() | nil,
          message_id: integer() | nil
        }

  @spec relations(Chat.t(), list(map()), map()) :: map()
  def relations(%Chat{} = chat, messages, actor) when is_list(messages) do
    active_message_ids = MapSet.new(messages, & &1.id)
    children = child_handoff_chats(chat.id, actor)

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
      parent: parent_relation(chat, actor),
      children_by_message_id: children_by_message_id,
      children_without_message: Enum.reverse(children_without_message)
    }
  end

  @spec parent_relation(Chat.t(), map()) :: relation_entry() | nil
  def parent_relation(%Chat{parent_chat_id: parent_chat_id} = chat, actor)
      when is_integer(parent_chat_id) do
    Chat
    |> Ash.Query.filter(id == ^parent_chat_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(relation_load(), strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = parent]} ->
        %{chat: parent, kind: chat.parent_relation_kind, message_id: chat.parent_message_id}

      _other ->
        nil
    end
  end

  def parent_relation(_chat, _actor), do: nil

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

  defp child_entry(%Chat{} = child) do
    %{chat: child, kind: child.parent_relation_kind, message_id: child.parent_message_id}
  end

  defp relation_load, do: [:bot, :last_message]
end
