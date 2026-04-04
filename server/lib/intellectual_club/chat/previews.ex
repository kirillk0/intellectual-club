defmodule IntellectualClub.Chat.Previews do
  @moduledoc """
  Helpers for compact chat and message previews.
  """

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

  @spec message_preview_text(map()) :: String.t()
  def message_preview_text(message) when is_map(message) do
    wanted_type =
      case Map.get(message, :role) do
        :user -> :input
        "user" -> :input
        :assistant -> :answer
        "assistant" -> :answer
        _ -> nil
      end

    {texts, media_count} =
      message
      |> Map.get(:steps, [])
      |> Enum.sort_by(&sort_seq/1)
      |> Enum.flat_map(fn step ->
        step
        |> Map.get(:items, [])
        |> Enum.sort_by(&sort_seq/1)
      end)
      |> Enum.filter(fn item -> wanted_type != nil and Map.get(item, :type) == wanted_type end)
      |> Enum.reduce({[], 0}, fn item, {texts, media_count} ->
        contents = Map.get(item, :contents) || []

        item_text =
          contents
          |> Enum.filter(fn content -> Map.get(content, :kind) in [:text, "text"] end)
          |> Enum.sort_by(&sort_seq/1)
          |> Enum.map(fn content -> to_string(Map.get(content, :content_text) || "") end)
          |> Enum.join("")

        item_media_count =
          Enum.count(contents, fn content ->
            Map.get(content, :kind) in [:media, "media"]
          end)

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

  @spec message_preview(map(), integer()) :: {String.t() | nil, String.t() | nil}
  def message_preview(message, limit) when is_map(message) and is_integer(limit) do
    role =
      case Map.get(message, :role) do
        :user -> "user"
        "user" -> "user"
        :assistant -> "assistant"
        "assistant" -> "assistant"
        _ -> nil
      end

    {format_preview(message_preview_text(message), limit), role}
  end

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0
end
