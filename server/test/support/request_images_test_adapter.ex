defmodule IntellectualClub.Generation.RequestImagesTestAdapter do
  @moduledoc """
  Test-only composite mapper for synthetic requests containing all provider shapes.
  Production adapters remain responsible for their own native image structures.
  """

  @container_types MapSet.new([
                     "message",
                     "user_input",
                     "model_output",
                     "tool_result"
                   ])

  def map_request_images(request, acc, mapper) when is_map(request) and is_function(mapper, 2) do
    Enum.reduce(["messages", "input"], {request, acc}, fn key, {current, current_acc} ->
      case Map.fetch(current, key) do
        {:ok, value} ->
          {mapped, next_acc} = walk_root(value, current_acc, mapper)
          {Map.put(current, key, mapped), next_acc}

        :error ->
          {current, current_acc}
      end
    end)
  end

  def map_request_images(request, acc, _mapper), do: {request, acc}

  defp walk_root(items, acc, mapper) when is_list(items) do
    map_list(items, acc, &walk_item(&1, &2, mapper))
  end

  defp walk_root(item, acc, mapper) when is_map(item), do: walk_item(item, acc, mapper)
  defp walk_root(other, acc, _mapper), do: {other, acc}

  defp walk_item(%{} = block, acc, mapper) do
    case image_marker(block) do
      {:ok, shape, marker} ->
        reference = reference(shape, block, marker)
        {change, acc} = mapper.(reference, acc)
        {apply_change(shape, block, change), acc}

      :not_image_marker ->
        walk_container(block, acc, mapper)
    end
  end

  defp walk_item(other, acc, _mapper), do: {other, acc}

  defp walk_container(%{} = container, acc, mapper) do
    type = string_value(Map.get(container, "type"))
    role = string_value(Map.get(container, "role"))

    cond do
      role != "" or MapSet.member?(@container_types, type) ->
        walk_key(container, "content", acc, mapper)

      type == "function_result" ->
        walk_key(container, "result", acc, mapper)

      true ->
        {container, acc}
    end
  end

  defp walk_key(container, key, acc, mapper) do
    case Map.fetch(container, key) do
      {:ok, children} when is_list(children) ->
        {mapped, next_acc} = map_list(children, acc, &walk_item(&1, &2, mapper))
        {Map.put(container, key, mapped), next_acc}

      _other ->
        {container, acc}
    end
  end

  defp map_list(items, acc, mapper) do
    {mapped, next_acc} =
      Enum.reduce(items, {[], acc}, fn item, {mapped_acc, current_acc} ->
        {mapped_item, item_acc} = mapper.(item, current_acc)
        {[mapped_item | mapped_acc], item_acc}
      end)

    {Enum.reverse(mapped), next_acc}
  end

  defp image_marker(%{"type" => "input_image", "image_url" => value}) do
    marker_result(:responses, value)
  end

  defp image_marker(%{"type" => "image_url", "image_url" => %{"url" => value}}) do
    marker_result(:openrouter, value)
  end

  defp image_marker(%{"type" => "image", "source" => %{"data" => value}}) do
    marker_result(:anthropic, value)
  end

  defp image_marker(%{"type" => "image", "data" => value}) do
    marker_result(:google, value)
  end

  defp image_marker(_block), do: :not_image_marker

  defp marker_result(shape, %{"$intellectual_club_file" => %{} = marker}) do
    {:ok, shape, marker}
  end

  defp marker_result(_shape, _value), do: :not_image_marker

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: ""

  defp reference(shape, block, marker) do
    format_key = if shape in [:responses, :openrouter], do: :data_url, else: :base64

    mime_type =
      case shape do
        :anthropic -> get_in(block, ["source", "media_type"])
        :google -> Map.get(block, "mime_type")
        _ -> Map.get(marker, "mime_type")
      end

    %{
      marker: marker,
      encoding: Atom.to_string(format_key),
      mime_type: mime_type,
      format_key: format_key,
      format: if(format_key == :data_url, do: &data_url/2, else: &base64/2)
    }
  end

  defp data_url(encoded, mime), do: "data:#{mime};base64," <> encoded
  defp base64(encoded, _mime), do: encoded

  defp apply_change(_shape, block, :keep), do: block

  defp apply_change(shape, block, {:marker, marker, mime}),
    do: put_image(shape, block, %{"$intellectual_club_file" => marker}, mime)

  defp apply_change(shape, block, {:wire, wire, mime}), do: put_image(shape, block, wire, mime)

  defp apply_change(:responses, _block, {:omit, text}),
    do: %{"type" => "input_text", "text" => text}

  defp apply_change(:anthropic, block, {:omit, text}) do
    Map.merge(%{"type" => "text", "text" => text}, Map.take(block, ["cache_control"]))
  end

  defp apply_change(_shape, _block, {:omit, text}), do: %{"type" => "text", "text" => text}

  defp put_image(:responses, block, value, _mime), do: Map.put(block, "image_url", value)

  defp put_image(:openrouter, block, value, _mime),
    do: Map.update!(block, "image_url", &Map.put(&1, "url", value))

  defp put_image(:anthropic, block, value, mime) do
    Map.update!(block, "source", fn source ->
      source |> Map.put("type", "base64") |> Map.put("media_type", mime) |> Map.put("data", value)
    end)
  end

  defp put_image(:google, block, value, mime),
    do: block |> Map.put("mime_type", mime) |> Map.put("data", value)
end
