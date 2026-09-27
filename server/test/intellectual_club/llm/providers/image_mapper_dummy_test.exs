defmodule IntellectualClub.Llm.Providers.ImageMapperDummy do
  @moduledoc false

  alias IntellectualClub.Llm.Providers.Common.ImageTraversal

  def map_request_images(request, acc, mapper) do
    ImageTraversal.map(request, acc, ["packets"], &map_block(&1, &2, mapper), &child_key/1)
  end

  defp child_key(%{"kind" => "packet"}), do: "parts"
  defp child_key(_block), do: nil

  defp map_block(
         %{"kind" => "picture", "attachment" => %{"$intellectual_club_file" => %{} = marker}} =
           block,
         acc,
         mapper
       ) do
    reference = %{
      marker: marker,
      encoding: "base64",
      mime_type: Map.get(block, "mime"),
      format_key: {__MODULE__, :picture_v1},
      format: fn base64, mime -> mime <> ":" <> base64 end
    }

    {change, acc} = mapper.(reference, acc)

    block =
      case change do
        :keep ->
          block

        {:marker, marker, mime} ->
          put_attachment(block, %{"$intellectual_club_file" => marker}, mime)

        {:wire, wire, mime} ->
          put_attachment(block, wire, mime)

        {:omit, text} ->
          %{"kind" => "caption", "value" => text}
      end

    {block, acc}
  end

  defp map_block(_block, _acc, _mapper), do: :skip

  defp put_attachment(block, attachment, mime) do
    block |> Map.put("attachment", attachment) |> Map.put("mime", mime)
  end
end
