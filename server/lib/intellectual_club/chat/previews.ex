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
    case structured_handoff_preview(message) do
      {text, _role} -> text
      nil -> regular_message_preview_text(message)
    end
  end

  @doc false
  def regular_item_types(:user), do: [:input, :handoff_request, :handoff_context]
  def regular_item_types(:assistant), do: [:answer, :handoff_summary]
  def regular_item_types(_role), do: []

  defp regular_message_preview_text(%ChatMessage{} = message) do
    wanted_types = regular_item_types(message.role)

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
          |> Enum.map_join("", &preview_text/1)

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
    {text, role} =
      case structured_handoff_preview(message) do
        {text, role} -> {text, role}
        nil -> {regular_message_preview_text(message), message_role(message.role)}
      end

    {format_preview(text, limit), role}
  end

  defp structured_handoff_preview(%ChatMessage{} = message) do
    items =
      message.steps
      |> Enum.sort_by(& &1.sequence)
      |> Enum.flat_map(fn %ChatMessageStep{} = step ->
        Enum.sort_by(step.items, & &1.sequence)
      end)

    history_items = Enum.filter(items, &(&1.type == :handoff_history))
    message_items = Enum.filter(items, &(&1.type == :handoff_message))

    cond do
      history_items == [] and message_items == [] ->
        nil

      true ->
        first_history_entry(history_items) || handoff_message_fallback(message_items)
    end
  end

  defp first_history_entry(items) do
    items
    |> Enum.flat_map(fn item -> Enum.sort_by(item.contents, & &1.sequence) end)
    |> Enum.find_value(fn content ->
      metadata = preview_metadata(content)
      entry_kind = Map.get(metadata, "entry_kind", Map.get(metadata, :entry_kind))
      role = Map.get(metadata, "role", Map.get(metadata, :role))
      text = content |> preview_text() |> String.trim()

      if content.kind == :text and entry_kind == "message" and text != "" do
        {text, message_role(role)}
      end
    end)
  end

  defp handoff_message_fallback(items) do
    text =
      items
      |> Enum.flat_map(fn item -> Enum.sort_by(item.contents, & &1.sequence) end)
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.map_join("", &preview_text/1)
      |> String.trim()

    if text == "", do: {"", "user"}, else: {text, "user"}
  end

  defp preview_text(%ChatMessageContent{} = content) do
    content.calculations
    |> Map.get(:preview_text, content.content_text)
    |> Kernel.||("")
    |> to_string()
  end

  defp preview_metadata(%ChatMessageContent{} = content) do
    case Map.get(content.calculations, :preview_metadata, content.content_json) do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp message_role(:user), do: "user"
  defp message_role("user"), do: "user"
  defp message_role(:assistant), do: "assistant"
  defp message_role("assistant"), do: "assistant"
  defp message_role(_role), do: nil
end
