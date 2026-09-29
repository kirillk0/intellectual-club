defmodule IntellectualClub.Llm.Providers.AnthropicMessages.ImageMapper do
  @moduledoc false

  alias IntellectualClub.Llm.Providers.Common.ImageTraversal

  def map_request_images(request, acc, mapper) when is_function(mapper, 2) do
    ImageTraversal.map(request, acc, ["messages"], &map_block(&1, &2, mapper), &child_key/1)
  end

  defp map_block(
         %{
           "type" => "image",
           "source" => %{"data" => %{"$intellectual_club_file" => %{} = marker}}
         } = block,
         acc,
         mapper
       ) do
    reference = %{
      marker: marker,
      encoding: "base64",
      mime_type: get_in(block, ["source", "media_type"]),
      format_key: :base64,
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

  defp format(base64, _mime), do: base64

  defp put_image(block, value, mime) do
    Map.update!(block, "source", fn source ->
      source
      |> Map.put("type", "base64")
      |> Map.put("media_type", mime)
      |> Map.put("data", value)
    end)
  end

  defp omit(block, text) do
    fallback = %{"type" => "text", "text" => text}

    case Map.get(block, "cache_control") do
      %{} = cache_control -> Map.put(fallback, "cache_control", cache_control)
      _other -> fallback
    end
  end
end
