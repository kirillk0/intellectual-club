defmodule IntellectualClub.Chat.Previews do
  @moduledoc """
  Helpers for compact chat and message previews.
  """

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep

  @spec format_preview(String.t() | nil, integer()) :: String.t() | nil
  def format_preview(content, limit) when is_integer(limit) do
    preview =
      content
      |> to_string()
      |> String.replace("\r", " ")
      |> String.replace("\n", " ")
      |> String.trim()

    cond do
      preview == "" ->
        nil

      String.length(preview) <= limit ->
        preview

      true ->
        String.slice(preview, 0, limit) <> "..."
    end
  end

  @spec message_preview_text(ChatMessage.t()) :: String.t()
  def message_preview_text(%ChatMessage{} = message) do
    wanted_types =
      case message.role do
        :user -> [:input, :handoff_request, :handoff_context]
        :assistant -> [:answer, :handoff_summary]
        _ -> []
      end

    {texts, media_count} =
      message.steps
      |> Enum.sort_by(& &1.sequence)
      |> Enum.flat_map(fn %ChatMessageStep{} = step ->
        Enum.sort_by(step.items, & &1.sequence)
      end)
      |> Enum.filter(fn %ChatMessageItem{} = item -> item.type in wanted_types end)
      |> Enum.reduce({[], 0}, fn %ChatMessageItem{} = item, {texts, media_count} ->
        contents = item.contents

        item_text =
          contents
          |> Enum.filter(fn %ChatMessageContent{} = content -> content.kind == :text end)
          |> Enum.sort_by(& &1.sequence)
          |> Enum.map_join("", & &1.content_text)

        item_media_count =
          Enum.count(contents, fn %ChatMessageContent{} = content -> content.kind == :media end)

        next_texts =
          if String.trim(item_text) == "" do
            texts
          else
            [item_text | texts]
          end

        {next_texts, media_count + item_media_count}
      end)

    case texts |> Enum.reverse() |> Enum.join("\n\n") |> String.trim() do
      "" when media_count == 1 -> "Attachment"
      "" when media_count > 1 -> "#{media_count} attachments"
      "" -> ""
      joined -> joined
    end
  end

  @spec message_preview(ChatMessage.t(), integer()) :: {String.t() | nil, String.t() | nil}
  def message_preview(%ChatMessage{} = message, limit) when is_integer(limit) do
    role =
      case message.role do
        :user -> "user"
        :assistant -> "assistant"
        _ -> nil
      end

    {format_preview(message_preview_text(message), limit), role}
  end
end
