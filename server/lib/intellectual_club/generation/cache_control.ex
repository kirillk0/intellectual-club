defmodule IntellectualClub.Generation.CacheControl do
  @moduledoc """
  Helpers for OpenRouter/Anthropic prompt cache markers.

  The marker is attached to the last text content block:
  `%{"type" => "text", "text" => "...", "cache_control" => %{"type" => "ephemeral"}}`.
  """

  @cache_control_payload %{"type" => "ephemeral"}

  @spec remove_cache_control(map()) :: map()
  def remove_cache_control(message) when is_map(message) do
    case content_of(message) do
      content when is_list(content) ->
        updated =
          Enum.map(content, fn
            %{} = block ->
              block
              |> Map.new()
              |> Map.delete("cache_control")
              |> Map.delete(:cache_control)

            other ->
              other
          end)

        put_content(message, updated)

      _other ->
        message
    end
  end

  @spec add_cache_control_to_last_text_block(map()) :: map()
  def add_cache_control_to_last_text_block(message) when is_map(message) do
    content = normalize_content(content_of(message))

    {updated, marked?} =
      content
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce_while({content, false}, fn {block, idx}, {acc, _marked?} ->
        if text_block?(block) do
          updated_block = Map.put(Map.new(block), "cache_control", @cache_control_payload)
          {:halt, {List.replace_at(acc, idx, updated_block), true}}
        else
          {:cont, {acc, false}}
        end
      end)

    updated =
      if marked? do
        updated
      else
        updated ++ [%{"type" => "text", "text" => "", "cache_control" => @cache_control_payload}]
      end

    put_content(message, updated)
  end

  @spec apply_system_prompt_marker([map()]) :: [map()]
  def apply_system_prompt_marker(messages) when is_list(messages) do
    {updated, _found?} =
      Enum.map_reduce(messages, false, fn message, found? ->
        role = role_of(message)

        cond do
          found? ->
            {message, true}

          role == "system" ->
            {add_cache_control_to_last_text_block(message), true}

          true ->
            {message, false}
        end
      end)

    updated
  end

  @spec apply_history_end_marker([map()], keyword()) :: [map()]
  def apply_history_end_marker(messages, opts) when is_list(messages) and is_list(opts) do
    history_length = Keyword.get(opts, :history_length, 0)

    cond do
      not is_integer(history_length) ->
        messages

      history_length <= 0 ->
        messages

      history_length > length(messages) ->
        messages

      true ->
        index = history_length - 1
        List.update_at(messages, index, &add_cache_control_to_last_text_block/1)
    end
  end

  @spec update_current_run_marker([map()], keyword()) :: {[map()], integer() | nil}
  def update_current_run_marker(messages, opts) when is_list(messages) and is_list(opts) do
    history_length = Keyword.get(opts, :history_length, 0)
    previous_marker_index = Keyword.get(opts, :previous_marker_index)

    messages =
      cond do
        not is_integer(previous_marker_index) ->
          messages

        previous_marker_index < history_length ->
          messages

        previous_marker_index >= length(messages) ->
          messages

        previous_marker_index == history_length - 1 ->
          messages

        true ->
          List.update_at(messages, previous_marker_index, &remove_cache_control/1)
      end

    if length(messages) <= history_length do
      {messages, nil}
    else
      current_index = length(messages) - 1

      {List.update_at(messages, current_index, &add_cache_control_to_last_text_block/1),
       current_index}
    end
  end

  defp normalize_content(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp normalize_content(%{} = content), do: [Map.new(content)]
  defp normalize_content(nil), do: [%{"type" => "text", "text" => ""}]

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{} = block -> Map.new(block)
      part when is_binary(part) -> %{"type" => "text", "text" => part}
      part -> %{"type" => "text", "text" => to_string(part)}
    end)
    |> case do
      [] -> [%{"type" => "text", "text" => ""}]
      list -> list
    end
  end

  defp normalize_content(other), do: [%{"type" => "text", "text" => to_string(other)}]

  defp text_block?(%{} = block) do
    type = Map.get(block, "type") || Map.get(block, :type)
    text = Map.get(block, "text") || Map.get(block, :text)

    type_text =
      cond do
        is_binary(type) -> type
        is_atom(type) -> Atom.to_string(type)
        true -> nil
      end

    type_text == "text" or (is_binary(text) and (is_nil(type_text) or type_text == ""))
  end

  defp text_block?(_other), do: false

  defp role_of(message) when is_map(message) do
    message
    |> Map.get("role", Map.get(message, :role))
    |> to_string()
    |> String.trim()
  end

  defp content_of(message) when is_map(message) do
    Map.get(message, "content", Map.get(message, :content))
  end

  defp put_content(message, content) when is_map(message) do
    cond do
      Map.has_key?(message, "content") -> Map.put(message, "content", content)
      Map.has_key?(message, :content) -> Map.put(message, :content, content)
      true -> Map.put(message, "content", content)
    end
  end
end
