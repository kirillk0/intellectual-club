defmodule IntellectualClub.Generation.RequestImages.Walker do
  @moduledoc false

  @container_types MapSet.new([
                     "message",
                     "user_input",
                     "model_output",
                     "tool_result"
                   ])

  @type provider_shape :: :responses | :openrouter | :anthropic | :google

  @type marker :: map()

  @spec map_images(map(), term(), (provider_shape(), map(), marker(), term() ->
                                     {map(), term()})) ::
          {map(), term()}
  def map_images(request, acc, mapper) when is_map(request) and is_function(mapper, 4) do
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

  def map_images(request, acc, _mapper), do: {request, acc}

  defp walk_root(items, acc, mapper) when is_list(items) do
    map_list(items, acc, &walk_item(&1, &2, mapper))
  end

  defp walk_root(item, acc, mapper) when is_map(item), do: walk_item(item, acc, mapper)
  defp walk_root(other, acc, _mapper), do: {other, acc}

  defp walk_item(%{} = block, acc, mapper) do
    case image_marker(block) do
      {:ok, shape, marker} ->
        mapper.(shape, block, marker, acc)

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
end
