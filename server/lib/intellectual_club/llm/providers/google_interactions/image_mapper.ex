defmodule IntellectualClub.Llm.Providers.GoogleInteractions.ImageMapper do
  @moduledoc false

  alias IntellectualClub.Llm.Providers.Common.ImageTraversal

  def map_request_images(request, acc, mapper) when is_function(mapper, 2) do
    ImageTraversal.map(request, acc, ["input"], &map_block(&1, &2, mapper), &child_key/1)
  end

  defp map_block(
         %{"type" => "image", "data" => %{"$intellectual_club_file" => %{} = marker}} = block,
         acc,
         mapper
       ) do
    reference = %{
      marker: marker,
      encoding: "base64",
      mime_type: Map.get(block, "mime_type"),
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

  defp child_key(%{"type" => type})
       when type in ["message", "user_input", "model_output", "tool_result"],
       do: "content"

  defp child_key(%{"type" => "function_result"}), do: "result"

  defp child_key(_block), do: nil

  defp format(base64, _mime), do: base64

  defp put_image(block, value, mime) do
    block
    |> Map.put("mime_type", mime)
    |> Map.put("data", value)
  end

  defp omit(_block, text), do: %{"type" => "text", "text" => text}
end
