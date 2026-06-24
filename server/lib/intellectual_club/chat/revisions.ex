defmodule IntellectualClub.Chat.Revisions do
  @moduledoc """
  Stable revision helpers for chat and chat list idle polling.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage

  @spec chat_list_revision(map(), term(), map(), [Chat.t()]) :: String.t()
  def chat_list_revision(pagination, bot_filter, page, chats) when is_list(chats) do
    revision_parts = [
      :chat_list,
      Map.get(pagination, :page),
      Map.get(pagination, :per_page),
      normalize_bot_filter(bot_filter),
      Map.get(page, :count, length(chats)),
      Enum.map(chats, &chat_list_revision_row/1)
    ]

    hash(revision_parts)
  end

  @spec chat_revision(Chat.t()) :: String.t()
  def chat_revision(%Chat{} = chat) do
    last_message = loaded_last_message(chat)

    [
      :chat,
      chat.id,
      datetime_revision_value(chat.updated_at),
      Map.get(chat, :last_message_id),
      active_generation_message_id(chat),
      message_status_revision_value(last_message),
      datetime_revision_value(Map.get(last_message || %{}, :updated_at))
    ]
    |> hash()
  end

  @spec active_generation_message_id(Chat.t()) :: integer() | nil
  def active_generation_message_id(%Chat{} = chat) do
    case loaded_last_message(chat) do
      %ChatMessage{id: id, status: status} when status in [:generating, "generating"] -> id
      _other -> nil
    end
  end

  @spec visible_active_generation_message_id([Chat.t()]) :: integer() | nil
  def visible_active_generation_message_id(chats) when is_list(chats) do
    Enum.find_value(chats, &active_generation_message_id/1)
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

  defp loaded_last_message(%Chat{} = chat) do
    case Map.get(chat, :last_message) do
      %Ash.NotLoaded{} -> nil
      %ChatMessage{} = message -> message
      _other -> nil
    end
  end

  defp message_status_revision_value(%ChatMessage{status: status}) when is_atom(status),
    do: Atom.to_string(status)

  defp message_status_revision_value(%ChatMessage{status: status}) when is_binary(status),
    do: status

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
