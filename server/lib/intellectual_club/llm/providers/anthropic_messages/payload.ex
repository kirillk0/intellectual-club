defmodule IntellectualClub.Llm.Providers.AnthropicMessages.Payload do
  @moduledoc """
  Payload projection for Anthropic Messages API.
  """

  @default_max_tokens 32_768
  @cache_control_payload %{"type" => "ephemeral"}
  @cacheable_block_types MapSet.new([
                           "text",
                           "image",
                           "document",
                           "tool_use",
                           "tool_result"
                         ])
  @reserved_parameter_keys MapSet.new([
                             "model",
                             "messages",
                             "system",
                             "stream",
                             "tools",
                             "tool_choice",
                             "max_output_tokens"
                           ])

  @spec build_messages_payload(String.t() | nil, map(), list(), keyword()) :: map()
  def build_messages_payload(model_name, parameters, messages, opts \\ [])
      when is_list(messages) and is_list(opts) do
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])

    parameters
    |> normalize_parameters()
    |> normalize_token_parameter()
    |> put_default_max_tokens()
    |> Map.put("model", model_name)
    |> Map.put("messages", normalize_messages(messages))
    |> Map.put("stream", true)
    |> maybe_put_system(system)
    |> maybe_put_tools(tools)
  end

  @spec from_chat_messages(list()) :: {String.t() | list(map()) | nil, list(map())}
  def from_chat_messages(messages) when is_list(messages) do
    {system_blocks, non_system_messages} =
      Enum.reduce(messages, {[], []}, fn message, {system_acc, message_acc} ->
        case normalized_role(message) do
          "system" ->
            {system_acc ++ content_blocks(Map.get(message, "content", Map.get(message, :content))),
             message_acc}

          _other ->
            {system_acc, message_acc ++ [message]}
        end
      end)

    {system_from_blocks(system_blocks), convert_messages(non_system_messages)}
  end

  def from_chat_messages(_messages), do: {nil, []}

  @spec request_snapshot(map()) :: map()
  def request_snapshot(%{} = raw_request) do
    payload = stringify_keys(raw_request)
    messages = normalize_messages(Map.get(payload, "messages"))

    %{
      model_input: messages,
      system_prompt: flatten_system(Map.get(payload, "system")),
      history_length: infer_history_length(messages, Map.get(payload, "system"))
    }
  end

  def request_snapshot(_raw_request),
    do: %{model_input: [], system_prompt: "", history_length: nil}

  @spec apply_followup_cache_control(map(), non_neg_integer()) :: map()
  def apply_followup_cache_control(raw_request, history_length)
      when is_map(raw_request) and is_integer(history_length) and history_length >= 0 do
    payload = stringify_keys(raw_request)

    messages =
      payload
      |> Map.get("messages")
      |> normalize_messages()
      |> apply_history_end_marker(history_length)
      |> clear_dynamic_cache_markers(history_length)
      |> add_dynamic_cache_marker(history_length)

    Map.put(payload, "messages", messages)
  end

  def apply_followup_cache_control(raw_request, _history_length), do: raw_request

  @spec anthropic_tools(list()) :: list(map())
  def anthropic_tools(tools) when is_list(tools) do
    tools
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn tool ->
      tool = stringify_keys(tool)

      case {Map.get(tool, "type"), Map.get(tool, "function")} do
        {"function", %{} = function} ->
          name = function |> Map.get("name") |> to_string() |> String.trim()

          if name == "" do
            []
          else
            [
              %{
                "name" => name,
                "description" => function |> Map.get("description", "") |> to_string(),
                "input_schema" => input_schema(Map.get(function, "parameters"))
              }
            ]
          end

        _other ->
          []
      end
    end)
  end

  def anthropic_tools(_tools), do: []

  @spec tool_result_content(term(), list()) :: String.t() | list(map())
  def tool_result_content(content, media_contents) when is_list(media_contents) do
    content_blocks = content_blocks(content)
    media_blocks = media_result_blocks(media_contents)
    blocks = content_blocks ++ media_blocks

    cond do
      blocks == [] ->
        ""

      text_only_blocks?(blocks) ->
        blocks
        |> Enum.map(&Map.get(&1, "text", ""))
        |> Enum.join("")

      true ->
        blocks
    end
  end

  def tool_result_content(content, _media_contents), do: tool_result_content(content, [])

  @spec normalize_tool_input(term()) :: map()
  def normalize_tool_input(%{} = input), do: stringify_keys(input)

  def normalize_tool_input(input) when is_binary(input) do
    case Jason.decode(String.trim(input)) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  def normalize_tool_input(_input), do: %{}

  @spec stringify_keys(term()) :: term()
  def stringify_keys(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_keys(nested_value)}
    end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  defp normalize_parameters(nil), do: %{}

  defp normalize_parameters(parameters) when is_map(parameters) do
    parameters
    |> stringify_keys()
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@reserved_parameter_keys, key) end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_parameters(_other), do: %{}

  defp normalize_token_parameter(%{"max_tokens" => _value} = parameters), do: parameters

  defp normalize_token_parameter(%{"max_output_tokens" => value} = parameters) do
    parameters
    |> Map.delete("max_output_tokens")
    |> Map.put("max_tokens", value)
  end

  defp normalize_token_parameter(parameters), do: parameters

  defp put_default_max_tokens(%{} = parameters) do
    Map.put_new(parameters, "max_tokens", @default_max_tokens)
  end

  defp maybe_put_system(payload, nil), do: payload
  defp maybe_put_system(payload, ""), do: payload
  defp maybe_put_system(payload, []), do: payload
  defp maybe_put_system(payload, system), do: Map.put(payload, "system", system)

  defp maybe_put_tools(payload, tools) do
    tools = anthropic_tools(tools)

    if tools == [] do
      payload
    else
      payload
      |> Map.put("tools", tools)
      |> Map.put_new("tool_choice", %{"type" => "auto"})
    end
  end

  defp normalize_messages(messages) when is_list(messages) do
    messages
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
  end

  defp normalize_messages(_messages), do: []

  defp convert_messages(messages) when is_list(messages), do: convert_messages(messages, [])

  defp convert_messages([], acc), do: acc

  defp convert_messages([message | rest], acc) do
    case normalized_role(message) do
      "tool" ->
        {tool_messages, rest} =
          Enum.split_while([message | rest], &(normalized_role(&1) == "tool"))

        blocks =
          tool_messages
          |> Enum.map(&tool_result_block/1)
          |> Enum.reject(&is_nil/1)

        next_acc =
          if blocks == [] do
            acc
          else
            append_message(acc, %{"role" => "user", "content" => blocks})
          end

        convert_messages(rest, next_acc)

      "user" ->
        content = message |> message_content() |> content_blocks() |> ensure_non_empty_content()
        convert_messages(rest, append_message(acc, %{"role" => "user", "content" => content}))

      "assistant" ->
        content =
          (message |> message_content() |> content_blocks()) ++ tool_use_blocks(message)

        if content == [] do
          convert_messages(rest, acc)
        else
          convert_messages(
            rest,
            append_message(acc, %{"role" => "assistant", "content" => content})
          )
        end

      _other ->
        convert_messages(rest, acc)
    end
  end

  defp append_message([], message), do: [message]

  defp append_message(acc, %{"role" => role, "content" => content} = message)
       when role in ["user", "assistant"] and is_list(content) do
    case List.last(acc) do
      %{"role" => ^role, "content" => previous_content} = previous
      when is_list(previous_content) ->
        List.replace_at(acc, -1, %{previous | "content" => previous_content ++ content})

      _other ->
        acc ++ [message]
    end
  end

  defp append_message(acc, message), do: acc ++ [message]

  defp normalized_role(%{} = message) do
    message
    |> Map.get("role", Map.get(message, :role))
    |> to_string()
    |> String.trim()
  end

  defp normalized_role(_message), do: ""

  defp message_content(%{} = message), do: Map.get(message, "content", Map.get(message, :content))
  defp message_content(_message), do: nil

  defp system_from_blocks([]), do: nil

  defp system_from_blocks(blocks) when is_list(blocks) do
    if Enum.any?(blocks, &Map.has_key?(&1, "cache_control")) do
      blocks
    else
      blocks
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join("")
      |> String.trim()
      |> case do
        "" -> nil
        text -> text
      end
    end
  end

  defp content_blocks(content) when is_binary(content) do
    if content == "", do: [], else: [%{"type" => "text", "text" => content}]
  end

  defp content_blocks(content) when is_list(content) do
    content
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&content_block/1)
  end

  defp content_blocks(%{} = content), do: content_block(content)
  defp content_blocks(nil), do: []
  defp content_blocks(content), do: [%{"type" => "text", "text" => to_string(content)}]

  defp content_block(%{"type" => "text"} = block) do
    text = block |> Map.get("text", Map.get(block, "content", "")) |> to_string()

    if text == "" do
      []
    else
      [maybe_copy_cache_control(%{"type" => "text", "text" => text}, block)]
    end
  end

  defp content_block(%{"type" => "image"} = block), do: [block]

  defp content_block(%{"type" => "image_url"} = block) do
    url =
      block
      |> Map.get("image_url", %{})
      |> case do
        %{} = image_url -> Map.get(image_url, "url")
        value -> value
      end

    case image_source_from_url(url) do
      nil -> []
      source -> [%{"type" => "image", "source" => source}]
    end
  end

  defp content_block(%{"type" => "input_image"} = block) do
    case image_source_from_url(Map.get(block, "image_url") || Map.get(block, "url")) do
      nil -> []
      source -> [%{"type" => "image", "source" => source}]
    end
  end

  defp content_block(%{"content" => content}), do: content_blocks(content)
  defp content_block(%{content: content}), do: content_blocks(content)
  defp content_block(_block), do: []

  defp text_only_blocks?(blocks) when is_list(blocks) do
    Enum.all?(blocks, &(is_map(&1) and Map.get(&1, "type") == "text"))
  end

  defp maybe_copy_cache_control(target, source) when is_map(target) and is_map(source) do
    case Map.get(source, "cache_control") || Map.get(source, :cache_control) do
      %{} = cache_control -> Map.put(target, "cache_control", cache_control)
      _other -> target
    end
  end

  defp ensure_non_empty_content([]), do: [%{"type" => "text", "text" => ""}]
  defp ensure_non_empty_content(content), do: content

  defp apply_history_end_marker(messages, history_length) do
    cond do
      history_length <= 0 ->
        messages

      history_length > length(messages) ->
        messages

      true ->
        List.update_at(messages, history_length - 1, &add_cache_control_to_last_block/1)
    end
  end

  defp clear_dynamic_cache_markers(messages, history_length) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      if index >= history_length do
        remove_cache_control(message)
      else
        message
      end
    end)
  end

  defp add_dynamic_cache_marker(messages, history_length) do
    if length(messages) <= history_length do
      messages
    else
      List.update_at(messages, length(messages) - 1, &add_cache_control_to_last_block/1)
    end
  end

  defp add_cache_control_to_last_block(%{} = message) do
    content = message |> message_content() |> normalize_content_blocks()

    {updated, marked?} =
      content
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce_while({content, false}, fn {block, index}, {acc, _marked?} ->
        if cacheable_block?(block) do
          updated_block = Map.put(block, "cache_control", @cache_control_payload)
          {:halt, {List.replace_at(acc, index, updated_block), true}}
        else
          {:cont, {acc, false}}
        end
      end)

    if marked? do
      Map.put(message, "content", updated)
    else
      message
    end
  end

  defp add_cache_control_to_last_block(message), do: message

  defp remove_cache_control(%{} = message) do
    content = message |> message_content() |> normalize_content_blocks()
    updated = Enum.map(content, &Map.delete(&1, "cache_control"))
    Map.put(message, "content", updated)
  end

  defp remove_cache_control(message), do: message

  defp normalize_content_blocks(content) when is_list(content) do
    content
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
  end

  defp normalize_content_blocks(content) when is_binary(content) do
    if content == "", do: [], else: [%{"type" => "text", "text" => content}]
  end

  defp normalize_content_blocks(%{} = content), do: [stringify_keys(content)]
  defp normalize_content_blocks(nil), do: []
  defp normalize_content_blocks(content), do: [%{"type" => "text", "text" => to_string(content)}]

  defp cacheable_block?(%{} = block) do
    type = block |> Map.get("type") |> to_string()

    cond do
      MapSet.member?(@cacheable_block_types, type) ->
        true

      type == "" and is_binary(Map.get(block, "text")) and Map.get(block, "text") != "" ->
        true

      true ->
        false
    end
  end

  defp cacheable_block?(_block), do: false

  defp infer_history_length(messages, system) when is_list(messages) do
    indices =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {message, index} ->
        if message_has_cache_control?(message) do
          [index]
        else
          []
        end
      end)

    case indices do
      [] ->
        if system_has_cache_control?(system), do: 0, else: nil

      values ->
        Enum.min(values) + 1
    end
  end

  defp infer_history_length(_messages, system) do
    if system_has_cache_control?(system), do: 0, else: nil
  end

  defp system_has_cache_control?(system) when is_list(system) do
    Enum.any?(system, fn
      %{} = block -> is_map(Map.get(stringify_keys(block), "cache_control"))
      _other -> false
    end)
  end

  defp system_has_cache_control?(_system), do: false

  defp message_has_cache_control?(%{} = message) do
    message
    |> message_content()
    |> case do
      content when is_list(content) ->
        Enum.any?(content, fn
          %{} = block -> is_map(Map.get(stringify_keys(block), "cache_control"))
          _other -> false
        end)

      _other ->
        false
    end
  end

  defp message_has_cache_control?(_message), do: false

  defp image_source_from_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "data:") ->
        parse_data_url(url)

      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        %{"type" => "url", "url" => url}

      true ->
        nil
    end
  end

  defp image_source_from_url(_url), do: nil

  defp parse_data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [media_type, data] when media_type != "" and data != "" ->
        %{"type" => "base64", "media_type" => media_type, "data" => data}

      _other ->
        nil
    end
  end

  defp tool_use_blocks(%{} = message) do
    message
    |> Map.get("tool_calls", Map.get(message, :tool_calls, []))
    |> case do
      calls when is_list(calls) -> calls
      _other -> []
    end
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&tool_use_block/1)
  end

  defp tool_use_blocks(_message), do: []

  defp tool_use_block(call) when is_map(call) do
    call = stringify_keys(call)
    function = Map.get(call, "function")
    function = if is_map(function), do: function, else: %{}

    id = call |> Map.get("id", Map.get(call, "call_id")) |> to_string() |> String.trim()
    name = function |> Map.get("name", Map.get(call, "name")) |> to_string() |> String.trim()

    cond do
      id == "" or name == "" ->
        []

      true ->
        [
          %{
            "type" => "tool_use",
            "id" => id,
            "name" => name,
            "input" =>
              normalize_tool_input(Map.get(function, "arguments", Map.get(call, "arguments")))
          }
        ]
    end
  end

  defp tool_result_block(%{} = message) do
    message = stringify_keys(message)
    tool_use_id = message |> Map.get("tool_call_id") |> to_string() |> String.trim()

    if tool_use_id == "" do
      nil
    else
      %{
        "type" => "tool_result",
        "tool_use_id" => tool_use_id,
        "content" => tool_result_content(message_content(message), [])
      }
    end
  end

  defp input_schema(%{} = schema), do: schema
  defp input_schema(_schema), do: %{"type" => "object", "properties" => %{}}

  defp media_result_blocks(media_contents) when is_list(media_contents) do
    media_contents
    |> Enum.flat_map(fn content ->
      content
      |> IntellectualClub.Chat.Media.chat_message_content(
        supports_image_input: true,
        provider_type: "anthropic_messages"
      )
      |> content_blocks()
    end)
  end

  defp flatten_system(nil), do: ""
  defp flatten_system(system) when is_binary(system), do: system

  defp flatten_system(system) when is_list(system) do
    system
    |> Enum.flat_map(&content_blocks/1)
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.join("")
  end

  defp flatten_system(system), do: to_string(system)
end
