defmodule IntellectualClub.Generation.LegacyRequestImages.Walker do
  @moduledoc false

  @container_types MapSet.new([
                     "message",
                     "user_input",
                     "model_output",
                     "tool_result"
                   ])

  @attachment_pattern ~r/\[Attached file\s+(file_id|content_id)=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:\s|\])/u

  @type provider_shape :: :responses | :openrouter | :anthropic | :google
  @type attachment_reference :: %{kind: :file | :content, external_id: String.t()}

  @spec compact(
          map(),
          term(),
          (provider_shape(), map(), map(), attachment_reference() | nil, term() ->
             {:ok, map(), term()} | {:error, term(), term()})
        ) :: {map(), term()}
  def compact(request, acc, mapper)
      when is_map(request) and is_function(mapper, 5) do
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

  def compact(request, acc, _mapper), do: {request, acc}

  defp walk_root(items, acc, mapper) when is_list(items),
    do: map_children(items, acc, mapper)

  defp walk_root(item, acc, mapper) when is_map(item), do: walk_item(item, acc, mapper)
  defp walk_root(other, acc, _mapper), do: {other, acc}

  defp walk_item(%{} = block, acc, mapper) do
    case legacy_image(block) do
      {:ok, shape, image} ->
        case mapper.(shape, block, image, nil, acc) do
          {:ok, mapped, next_acc} -> {mapped, next_acc}
          {:error, _reason, next_acc} -> {block, next_acc}
        end

      :not_legacy_image ->
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
        {mapped, next_acc} = map_children(children, acc, mapper)
        {Map.put(container, key, mapped), next_acc}

      _other ->
        {container, acc}
    end
  end

  defp map_children(children, acc, mapper) do
    {mapped, next_acc, _previous_reference} =
      Enum.reduce(children, {[], acc, nil}, fn child, {mapped_acc, current_acc, previous_ref} ->
        case legacy_image(child) do
          {:ok, shape, image} ->
            case mapper.(shape, child, image, previous_ref, current_acc) do
              {:ok, mapped_child, child_acc} ->
                {[mapped_child | mapped_acc], child_acc, nil}

              {:error, _reason, child_acc} ->
                {[child | mapped_acc], child_acc, nil}
            end

          :not_legacy_image ->
            {mapped_child, child_acc} = walk_item(child, current_acc, mapper)

            {
              [mapped_child | mapped_acc],
              child_acc,
              attachment_reference(child)
            }
        end
      end)

    {Enum.reverse(mapped), next_acc}
  end

  defp legacy_image(%{"type" => "input_image", "image_url" => value})
       when is_binary(value) do
    case data_url(value) do
      {:ok, image} -> {:ok, :responses, image}
      :not_data_url -> :not_legacy_image
    end
  end

  defp legacy_image(%{"type" => "image_url", "image_url" => %{"url" => value}})
       when is_binary(value) do
    case data_url(value) do
      {:ok, image} -> {:ok, :openrouter, image}
      :not_data_url -> :not_legacy_image
    end
  end

  defp legacy_image(%{
         "type" => "image",
         "source" => %{"type" => "base64", "data" => data} = source
       })
       when is_binary(data) do
    {:ok, :anthropic,
     %{
       encoded: data,
       declared_mime_type: Map.get(source, "media_type"),
       encoded_chars: byte_size(data)
     }}
  end

  defp legacy_image(%{"type" => "image", "data" => data} = block)
       when is_binary(data) do
    {:ok, :google,
     %{
       encoded: data,
       declared_mime_type: Map.get(block, "mime_type"),
       encoded_chars: byte_size(data)
     }}
  end

  defp legacy_image(_block), do: :not_legacy_image

  defp data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [mime_type, encoded] when mime_type != "" and encoded != "" ->
        {:ok,
         %{
           encoded: encoded,
           declared_mime_type: mime_type,
           encoded_chars: byte_size(encoded)
         }}

      _other ->
        :not_data_url
    end
  end

  defp data_url(_value), do: :not_data_url

  defp attachment_reference(%{} = block) do
    text = Map.get(block, "text")

    if is_binary(text) do
      case Regex.run(@attachment_pattern, text, capture: :all_but_first) do
        ["file_id", external_id] ->
          %{kind: :file, external_id: String.downcase(external_id)}

        ["content_id", external_id] ->
          %{kind: :content, external_id: String.downcase(external_id)}

        _other ->
          nil
      end
    end
  end

  defp attachment_reference(_block), do: nil

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: ""
end
