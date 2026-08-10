defmodule IntellectualClub.Chat.Revisions do
  @moduledoc """
  Stable revision helpers for chat and chat list idle polling.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage

  @spec chat_list_revision(map(), term(), map(), [Chat.t()]) :: String.t()
  def chat_list_revision(pagination, bot_filter, page, chats) when is_list(chats) do
    chat_list_revision(pagination, bot_filter, page, chats, %{})
  end

  @spec chat_list_revision(map(), term(), map(), [Chat.t()], map()) :: String.t()
  def chat_list_revision(pagination, bot_filter, page, chats, lifecycle_states)
      when is_list(chats) and is_map(lifecycle_states) do
    revision_parts = [
      :chat_list,
      Map.get(pagination, :page),
      Map.get(pagination, :per_page),
      normalize_bot_filter(bot_filter),
      Map.get(page, :count, length(chats)),
      Enum.map(chats, &chat_list_revision_row/1),
      lifecycle_revision_rows(lifecycle_states)
    ]

    hash(revision_parts)
  end

  @spec chat_revision(Chat.t()) :: String.t()
  def chat_revision(%Chat{} = chat) do
    chat_revision(chat, [], [])
  end

  @spec chat_revision(Chat.t(), [Chat.t()]) :: String.t()
  def chat_revision(%Chat{} = chat, related_chats) when is_list(related_chats) do
    chat_revision(chat, related_chats, [])
  end

  @spec chat_revision(Chat.t(), [Chat.t()], [map()]) :: String.t()
  def chat_revision(%Chat{} = chat, related_chats, queued_messages)
      when is_list(related_chats) and is_list(queued_messages) do
    chat_revision(chat, related_chats, queued_messages, %{})
  end

  @spec chat_revision(Chat.t(), [Chat.t()], [map()], map()) :: String.t()
  def chat_revision(%Chat{} = chat, related_chats, queued_messages, lifecycle_states)
      when is_list(related_chats) and is_list(queued_messages) and is_map(lifecycle_states) do
    last_message = loaded_last_message(chat)

    [
      :chat,
      chat.id,
      datetime_revision_value(chat.updated_at),
      Map.get(chat, :last_message_id),
      active_generation_message_id(chat),
      message_status_revision_value(last_message),
      datetime_revision_value(Map.get(last_message || %{}, :updated_at)),
      relation_revision_rows(related_chats),
      lifecycle_revision_rows(lifecycle_states),
      queue_revision_rows(queued_messages)
    ]
    |> hash()
  end

  @spec active_generation_message_id(Chat.t()) :: integer() | nil
  def active_generation_message_id(%Chat{} = chat) do
    case loaded_last_message(chat) do
      %ChatMessage{id: id, status: :generating} -> id
      _other -> nil
    end
  end

  @spec visible_active_generation_message_id([Chat.t()]) :: integer() | nil
  def visible_active_generation_message_id(chats) when is_list(chats) do
    visible_active_generation_message_id(chats, %{})
  end

  @spec visible_active_generation_message_id([Chat.t()], map()) :: integer() | nil
  def visible_active_generation_message_id(chats, lifecycle_states)
      when is_list(chats) and is_map(lifecycle_states) do
    Enum.find_value(chats, &active_generation_message_id/1)
    |> case do
      id when is_integer(id) ->
        id

      _other ->
        lifecycle_states
        |> Enum.sort_by(fn {chat_id, _state} -> chat_id end)
        |> Enum.find_value(fn {_chat_id, state} ->
          Map.get(state, :active_generation_message_id)
        end)
    end
  end

  @spec client_revision_matches?(map(), String.t()) :: boolean()
  def client_revision_matches?(params, revision) when is_map(params) do
    params
    |> Map.get("revision", "")
    |> to_string()
    |> String.trim()
    |> Kernel.==(revision)
  end

  defp chat_list_revision_row(%Chat{} = chat) do
    last_message = loaded_last_message(chat)

    [
      chat.id,
      datetime_revision_value(chat.updated_at),
      Map.get(chat, :last_message_id),
      count_revision_value(Map.get(chat, :blocks_count)),
      count_revision_value(Map.get(chat, :tools_count)),
      active_generation_message_id(chat),
      message_status_revision_value(last_message),
      datetime_revision_value(Map.get(last_message || %{}, :updated_at))
    ]
  end

  defp relation_revision_rows(chats) when is_list(chats) do
    chats
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn chat ->
      last_message = loaded_last_message(chat)

      [
        chat.id,
        Map.get(chat, :parent_message_id),
        Map.get(chat, :parent_relation_kind),
        datetime_revision_value(chat.updated_at),
        Map.get(chat, :last_message_id),
        active_generation_message_id(chat),
        message_status_revision_value(last_message),
        datetime_revision_value(Map.get(last_message || %{}, :updated_at))
      ]
    end)
  end

  defp lifecycle_revision_rows(states) when is_map(states) do
    states
    |> Enum.sort_by(fn {chat_id, _state} -> chat_id end)
    |> Enum.map(fn {chat_id, state} ->
      [
        chat_id,
        Map.get(state, :chat_id),
        Map.get(state, :message_id),
        Map.get(state, :active_generation_message_id),
        Map.get(state, :last_message_status),
        datetime_revision_value(Map.get(state, :updated_at))
      ]
    end)
  end

  defp queue_revision_rows(queued_messages) do
    queued_messages
    |> Enum.sort_by(&Map.get(&1, :id))
    |> Enum.map(fn queued_message ->
      [
        Map.get(queued_message, :id),
        Map.get(queued_message, :kind),
        Map.get(queued_message, :status),
        Map.get(queued_message, :blocked_reason),
        Map.get(queued_message, :anchor_message_id),
        Map.get(queued_message, :target_generation_message_id),
        datetime_revision_value(Map.get(queued_message, :updated_at)),
        queue_content_revision_rows(Map.get(queued_message, :contents))
      ]
    end)
  end

  defp queue_content_revision_rows(%Ash.NotLoaded{}), do: []

  defp queue_content_revision_rows(contents) when is_list(contents) do
    contents
    |> Enum.sort_by(&Map.get(&1, :sequence))
    |> Enum.map(fn content ->
      [
        Map.get(content, :id),
        Map.get(content, :sequence),
        Map.get(content, :kind),
        Map.get(content, :content_text),
        Map.get(content, :file_id),
        datetime_revision_value(Map.get(content, :updated_at))
      ]
    end)
  end

  defp queue_content_revision_rows(_contents), do: []

  defp loaded_last_message(%Chat{} = chat) do
    case Map.get(chat, :last_message) do
      %Ash.NotLoaded{} -> nil
      %ChatMessage{} = message -> message
      _other -> nil
    end
  end

  defp message_status_revision_value(%ChatMessage{status: status}) when is_atom(status),
    do: Atom.to_string(status)

  defp message_status_revision_value(_message), do: nil

  defp count_revision_value(%Ash.NotLoaded{}), do: nil
  defp count_revision_value(value) when is_integer(value), do: value
  defp count_revision_value(_value), do: nil

  defp datetime_revision_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp datetime_revision_value(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp datetime_revision_value(_value), do: nil

  defp normalize_bot_filter(nil), do: nil
  defp normalize_bot_filter(:none), do: "none"
  defp normalize_bot_filter(bot_id) when is_integer(bot_id), do: bot_id
  defp normalize_bot_filter(other), do: to_string(other)

  defp hash(parts) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(parts))
    |> Base.url_encode64(padding: false)
  end
end
