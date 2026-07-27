defmodule IntellectualClubWeb.Bff.ChatQueuedMessagePayload do
  @moduledoc """
  Serializes durable chat queue entries for SPA payloads.
  """

  alias IntellectualClub.Chat.QueuedMessage
  alias IntellectualClub.Chat.QueuedMessageContent
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  @spec list_for_chat(integer(), map()) :: [map()]
  def list_for_chat(chat_id, actor) when is_integer(chat_id) and is_map(actor) do
    case QueuedMessages.list_for_chat(chat_id, actor) do
      {:ok, queued_messages} -> queued_messages(queued_messages)
      {:error, _error} -> []
    end
  end

  @spec queued_messages([QueuedMessage.t()]) :: [map()]
  def queued_messages(queued_messages) when is_list(queued_messages) do
    {payloads, _position} =
      Enum.map_reduce(queued_messages, 0, fn queued_message, follow_up_position ->
        position =
          if queued_message.kind == :follow_up,
            do: follow_up_position + 1,
            else: nil

        next_position = position || follow_up_position
        {queued_message(queued_message, position), next_position}
      end)

    payloads
  end

  @spec queued_message(QueuedMessage.t()) :: map()
  def queued_message(%QueuedMessage{} = queued_message) do
    queued_message(queued_message, follow_up_position(queued_message))
  end

  defp queued_message(%QueuedMessage{} = queued_message, position) do
    %{
      id: queued_message.id,
      chat_id: queued_message.chat_id,
      kind: atom_string(queued_message.kind),
      status: atom_string(queued_message.status),
      position: position,
      blocked_reason: queued_message.blocked_reason,
      attempt_count: queued_message.attempt_count,
      anchor_message_id: queued_message.anchor_message_id,
      target_generation_message_id: queued_message.target_generation_message_id,
      user_message_id: queued_message.user_message_id,
      assistant_message_id: queued_message.assistant_message_id,
      steering_item_id: queued_message.steering_item_id,
      created_at: Serializer.datetime_iso(queued_message.created_at),
      updated_at: Serializer.datetime_iso(queued_message.updated_at),
      finished_at: Serializer.datetime_iso(queued_message.finished_at),
      contents:
        queued_message
        |> Map.get(:contents, [])
        |> loaded_list()
        |> Enum.sort_by(& &1.sequence)
        |> Enum.map(&content(queued_message.id, &1))
    }
  end

  defp content(_queued_message_id, %QueuedMessageContent{kind: :text} = content) do
    %{
      id: content.id,
      sequence: content.sequence,
      kind: "text",
      content_text: content.content_text || ""
    }
  end

  defp content(queued_message_id, %QueuedMessageContent{kind: :media} = content) do
    url =
      "/api/bff/chat-queued-messages/#{queued_message_id}/contents/#{content.id}/file"

    %{
      id: content.id,
      sequence: content.sequence,
      kind: "media",
      content_text: content.content_text || "",
      file: file(content.file, url),
      url: url
    }
  end

  defp file(%Ash.NotLoaded{}, _url), do: nil
  defp file(nil, _url), do: nil

  defp file(file, url) do
    %{
      id: Map.get(file, :id),
      external_id: Map.get(file, :external_id),
      filename: Map.get(file, :filename),
      mime_type: Map.get(file, :mime_type),
      size_bytes: Map.get(file, :size_bytes),
      url: url
    }
  end

  defp loaded_list(%Ash.NotLoaded{}), do: []
  defp loaded_list(value) when is_list(value), do: value
  defp loaded_list(_value), do: []

  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: to_string(value)

  defp follow_up_position(%QueuedMessage{kind: :follow_up, status: status} = queued_message)
       when status in [:pending, :blocked] do
    QueuedMessage
    |> Ash.Query.filter(
      chat_id == ^queued_message.chat_id and kind == :follow_up and
        status in [:pending, :blocked] and id <= ^queued_message.id
    )
    |> Ash.count!(authorize?: false)
  end

  defp follow_up_position(_queued_message), do: nil
end
