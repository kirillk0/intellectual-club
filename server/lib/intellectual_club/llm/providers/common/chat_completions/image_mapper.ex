defmodule IntellectualClub.Llm.Providers.Common.ChatCompletions.ImageMapper do
  @moduledoc false

  alias IntellectualClub.Llm.Providers.Common.ImageTraversal

  def map_request_images(request, acc, mapper) when is_function(mapper, 2) do
    ImageTraversal.map(request, acc, ["messages"], &map_block(&1, &2, mapper), &child_key/1)
  end

  defp map_block(
         %{
           "type" => "image_url",
           "image_url" => %{"url" => %{"$intellectual_club_file" => %{} = marker}}
         } = block,
         acc,
         mapper
       ) do
    reference = %{
      marker: marker,
      encoding: "data_url",
      mime_type: Map.get(marker, "mime_type"),
      format_key: :data_url,
      format: &format/2
    }

    {change, acc} = mapper.(reference, acc)

    mapped =
      case change do
        :keep ->
          block

        {:marker, updated_marker, mime} ->
          put_image(block, %{"$intellectual_club_file" => updated_marker}, mime)

        {:wire, wire, mime} ->
          put_image(block, wire, mime)

        {:omit, text} ->
          omit(block, text)
      end

    {mapped, acc}
  end

  defp map_block(_block, _acc, _mapper), do: :skip

  defp child_key(%{"role" => role}) when is_binary(role) and role != "", do: "content"

  defp child_key(%{"type" => type}) when type in ["message", "tool_result"],
    do: "content"

  defp child_key(_block), do: nil

  defp format(base64, mime), do: "data:#{mime};base64," <> base64

  defp put_image(block, value, _mime) do
    Map.update!(block, "image_url", &Map.put(&1, "url", value))
  end

  defp omit(_block, text), do: %{"type" => "text", "text" => text}
end
