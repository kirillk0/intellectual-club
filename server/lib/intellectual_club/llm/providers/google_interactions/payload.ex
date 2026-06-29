defmodule IntellectualClub.Llm.Providers.GoogleInteractions.Payload do
  @moduledoc """
  Payload projection for the Google Interactions API.
  """

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.NativeModalities
  alias IntellectualClub.Generation.RequestPayload

  @generation_config_keys MapSet.new([
                            "temperature",
                            "top_p",
                            "seed",
                            "stop_sequences",
                            "thinking_level",
                            "thinking_summaries",
                            "max_output_tokens",
                            "max_tokens",
                            "presence_penalty",
                            "frequency_penalty",
                            "tool_choice"
                          ])

  @reserved_top_level_keys MapSet.new([
                             "model",
                             "agent",
                             "input",
                             "system_instruction",
                             "tools",
                             "stream",
                             "store",
                             "background",
                             "generation_config",
                             "agent_config",
                             "previous_interaction_id"
                           ])

  @step_types MapSet.new([
                "user_input",
                "model_output",
                "thought",
                "function_call",
                "function_result"
              ])

  @spec build_interaction_payload(String.t() | nil, map(), list(), keyword()) :: map()
  def build_interaction_payload(model_name, parameters, input_steps, opts \\ [])
      when is_list(input_steps) and is_list(opts) do
    system_instruction = Keyword.get(opts, :system_instruction)
    tools = Keyword.get(opts, :tools, [])

    parameters
    |> normalize_parameters()
    |> split_generation_config()
    |> then(fn {payload, generation_config} ->
      payload
      |> Map.put("model", model_name)
      |> Map.put("input", normalize_steps(input_steps))
      |> Map.put("stream", true)
      |> Map.put("store", false)
      |> maybe_put_system_instruction(system_instruction)
      |> maybe_put_generation_config(generation_config)
      |> maybe_put_tools(tools)
    end)
  end

  @spec build_input_steps(list(), keyword()) :: list(map())
  def build_input_steps(history, opts \\ []) when is_list(history) and is_list(opts) do
    history
    |> Enum.flat_map(&steps_from_history_entry(&1, opts))
    |> normalize_steps()
  end

  @spec request_snapshot(map()) :: map()
  def request_snapshot(%{} = raw_request) do
    payload = RequestPayload.stringify_keys(raw_request)

    %{
      model_input: normalize_steps(Map.get(payload, "input")),
      system_prompt: payload |> Map.get("system_instruction") |> to_string()
    }
  end

  def request_snapshot(_raw_request), do: %{model_input: [], system_prompt: ""}

  @spec parameters_from_request(map(), map()) :: map()
  def parameters_from_request(previous_raw_request, fallback) when is_map(previous_raw_request) do
    payload = RequestPayload.stringify_keys(previous_raw_request)

    parameters =
      payload
      |> Map.drop(MapSet.to_list(@reserved_top_level_keys))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    generation_config =
      case Map.get(payload, "generation_config") do
        %{} = value -> value
        _other -> %{}
      end

    parameters =
      if map_size(generation_config) > 0 do
        Map.put(parameters, "generation_config", generation_config)
      else
        parameters
      end

    if map_size(parameters) > 0 do
      parameters
    else
      RequestPayload.stringify_keys(fallback || %{})
    end
  end

  def parameters_from_request(_previous_raw_request, fallback),
    do: RequestPayload.stringify_keys(fallback || %{})

  @spec previous_input_steps(map()) :: list(map())
  def previous_input_steps(previous_raw_request) when is_map(previous_raw_request) do
    previous_raw_request
    |> RequestPayload.stringify_keys()
    |> Map.get("input")
    |> normalize_steps()
  end

  def previous_input_steps(_previous_raw_request), do: []

  @spec response_steps(term()) :: list(map())
  def response_steps(%{"steps" => steps}) when is_list(steps), do: normalize_steps(steps)
  def response_steps(%{steps: steps}) when is_list(steps), do: normalize_steps(steps)
  def response_steps(_raw_response), do: []

  @spec function_result_step(map(), keyword()) :: map()
  def function_result_step(result, opts \\ []) when is_map(result) and is_list(opts) do
    call_id = result_value(result, :call_id) |> to_string() |> String.trim()
    name = result_value(result, :name) |> to_string() |> String.trim()

    %{
      "type" => "function_result",
      "call_id" => call_id,
      "name" => name,
      "result" =>
        tool_result_content(
          result_value(result, :text),
          result_value(result, :media_contents),
          opts
        )
    }
    |> maybe_delete_blank("name")
  end

  @spec tool_result_content(term(), term(), keyword()) :: list(map()) | String.t() | map()
  def tool_result_content(text, media_contents, opts \\ []) when is_list(opts) do
    media_contents = if is_list(media_contents), do: media_contents, else: []

    text_blocks =
      text
      |> to_string()
      |> case do
        "" -> []
        value -> [%{"type" => "text", "text" => value}]
      end

    media_blocks =
      media_contents
      |> Enum.filter(&Media.media_content?/1)
      |> Enum.sort_by(&History.sort_seq/1)
      |> Enum.flat_map(&media_content_blocks(&1, opts))

    blocks = text_blocks ++ media_blocks

    if blocks == [] do
      ""
    else
      blocks
    end
  end

  @spec google_tools(list()) :: list(map())
  def google_tools(tools) when is_list(tools) do
    tools
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&normalize_tool/1)
    |> dedupe_tools()
  end

  def google_tools(_tools), do: []

  @spec normalize_tool_call_arguments(term()) :: map()
  def normalize_tool_call_arguments(%{} = value), do: RequestPayload.stringify_keys(value)

  def normalize_tool_call_arguments(value) when is_binary(value) do
    case Jason.decode(String.trim(value)) do
      {:ok, %{} = decoded} -> RequestPayload.stringify_keys(decoded)
      _other -> %{}
    end
  end

  def normalize_tool_call_arguments(_value), do: %{}

  defp steps_from_history_entry(message, opts) when is_map(message) do
    if History.trace_message?(message) do
      trace_steps_from_history_entry(message, opts)
    else
      legacy_steps_from_history_entry(message, opts)
    end
  end

  defp steps_from_history_entry(_message, _opts), do: []

  defp legacy_steps_from_history_entry(message, opts) do
    case History.normalize_message(message) do
      %{"role" => "user", "content" => content} ->
        [%{"type" => "user_input", "content" => content_blocks(content, opts)}]

      %{"role" => "assistant", "content" => content} ->
        [%{"type" => "model_output", "content" => content_blocks(content, opts)}]

      _other ->
        []
    end
  end

  defp trace_steps_from_history_entry(message, opts) do
    case History.message_role(message) do
      "user" ->
        contents = History.project_contents_for_item_type(message, :input)
        [%{"type" => "user_input", "content" => content_blocks(contents, opts)}]

      "assistant" ->
        steps =
          message
          |> History.steps()
          |> Enum.sort_by(&History.sort_seq/1)
          |> Enum.flat_map(&steps_from_trace_step(&1, opts))

        if steps == [] do
          fallback_text = History.project_text_for_item_type(message, :answer)

          if String.trim(fallback_text) == "" do
            []
          else
            [
              %{
                "type" => "model_output",
                "content" => [%{"type" => "text", "text" => fallback_text}]
              }
            ]
          end
        else
          steps
        end

      _other ->
        []
    end
  end

  defp steps_from_trace_step(step, opts) do
    step
    |> History.items()
    |> Enum.sort_by(&History.sort_seq/1)
    |> Enum.flat_map(&step_from_trace_item(&1, opts))
  end

  defp step_from_trace_item(item, opts) do
    case google_step_from_opaque(item) do
      %{} = step ->
        [step]

      _other ->
        step_from_generic_trace_item(item, opts)
    end
  end

  defp step_from_generic_trace_item(item, opts) do
    case History.item_type(item) do
      :reasoning ->
        summary = content_blocks(History.item_text(item), opts)

        if summary == [] do
          []
        else
          [%{"type" => "thought", "summary" => summary}]
        end

      :answer ->
        content = content_blocks(History.item_text(item), opts)

        if content == [] do
          []
        else
          [%{"type" => "model_output", "content" => content}]
        end

      :tool_call ->
        case generic_function_call_step(item) do
          %{} = step -> [step]
          _other -> []
        end

      :tool_result ->
        case generic_function_result_step(item, opts) do
          %{} = step -> [step]
          _other -> []
        end

      _other ->
        []
    end
  end

  defp google_step_from_opaque(item) do
    item
    |> History.opaque_payloads()
    |> Enum.find_value(fn payload ->
      cond do
        is_map(Map.get(payload, "google_interaction_step")) ->
          Map.get(payload, "google_interaction_step")

        MapSet.member?(@step_types, to_string(Map.get(payload, "type") || "")) ->
          payload

        true ->
          nil
      end
    end)
    |> normalize_step_or_nil()
  end

  defp generic_function_call_step(item) do
    item
    |> tool_meta()
    |> case do
      %{} = meta ->
        raw = Map.get(meta, "raw")
        raw = if is_map(raw), do: RequestPayload.stringify_keys(raw), else: %{}

        id =
          [
            Map.get(meta, "call_id"),
            Map.get(meta, "tool_call_id"),
            Map.get(raw, "id"),
            Map.get(raw, "call_id")
          ]
          |> first_present_string()

        name =
          [
            Map.get(meta, "name"),
            Map.get(raw, "name"),
            get_in(raw, ["function", "name"])
          ]
          |> first_present_string()

        arguments =
          [
            Map.get(meta, "arguments"),
            Map.get(raw, "arguments"),
            get_in(raw, ["function", "arguments"])
          ]
          |> Enum.find(&present?/1)
          |> normalize_tool_call_arguments()

        if id == "" or name == "" do
          nil
        else
          %{"type" => "function_call", "id" => id, "name" => name, "arguments" => arguments}
          |> maybe_put_non_empty(
            "signature",
            Map.get(raw, "signature") || Map.get(meta, "signature")
          )
        end

      _other ->
        nil
    end
  end

  defp generic_function_result_step(item, opts) do
    meta = tool_meta(item)
    call_id = first_present_string([Map.get(meta, "call_id"), Map.get(meta, "tool_call_id")])

    if call_id == "" do
      nil
    else
      %{
        "type" => "function_result",
        "call_id" => call_id,
        "name" => Map.get(meta, "name", ""),
        "result" =>
          tool_result_content(
            History.item_text(item),
            History.media_contents_for_item(item),
            opts
          )
      }
      |> maybe_delete_blank("name")
    end
  end

  defp tool_meta(item) do
    item
    |> History.opaque_payloads()
    |> Enum.find(%{}, fn payload ->
      Map.has_key?(payload, "tool_call_id") or Map.has_key?(payload, "call_id") or
        Map.has_key?(payload, "raw") or Map.has_key?(payload, "name")
    end)
  end

  defp content_blocks(contents, opts) when is_list(contents) and is_list(opts) do
    contents
    |> Enum.flat_map(fn
      %{} = content ->
        case content_kind(content) do
          :text ->
            text = map_get(content, :content_text, "content_text", "") |> to_string()
            if text == "", do: [], else: [%{"type" => "text", "text" => text}]

          :media ->
            media_content_blocks(content, opts)

          _other ->
            []
        end

      other ->
        content_blocks(other, opts)
    end)
  end

  defp content_blocks(content, opts) when is_binary(content) and is_list(opts) do
    if content == "", do: [], else: [%{"type" => "text", "text" => content}]
  end

  defp content_blocks(%{} = content, opts) when is_list(opts) do
    type = content |> map_get(:type, "type") |> to_string()

    cond do
      type == "text" ->
        text = content |> map_get(:text, "text", "") |> to_string()
        if text == "", do: [], else: [%{"type" => "text", "text" => text}]

      type == "image" ->
        [RequestPayload.stringify_keys(content)]

      true ->
        []
    end
  end

  defp content_blocks(nil, _opts), do: []
  defp content_blocks(content, opts), do: content |> to_string() |> content_blocks(opts)

  defp media_content_blocks(content, opts) when is_map(content) and is_list(opts) do
    supports_image_input = Keyword.get(opts, :supports_image_input, false)
    placeholder = [%{"type" => "text", "text" => Media.placeholder_text(content)}]

    if supports_image_input do
      case NativeModalities.project_media_content(content, opts) do
        {:ok, %{modality: :image, mime_type: mime_type, data_url: data_url}} ->
          case split_data_url(data_url) do
            {:ok, data} ->
              placeholder ++ [%{"type" => "image", "data" => data, "mime_type" => mime_type}]

            :error ->
              placeholder
          end

        {:error, text} when is_binary(text) ->
          placeholder ++ [%{"type" => "text", "text" => text}]

        _other ->
          placeholder
      end
    else
      placeholder
    end
  end

  defp split_data_url("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [_meta, data] when data != "" -> {:ok, data}
      _other -> :error
    end
  end

  defp split_data_url(_data_url), do: :error

  defp normalize_parameters(nil), do: %{}

  defp normalize_parameters(parameters) when is_map(parameters) do
    parameters
    |> RequestPayload.stringify_keys()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_parameters(_parameters), do: %{}

  defp split_generation_config(parameters) when is_map(parameters) do
    configured_generation_config =
      case Map.get(parameters, "generation_config") do
        %{} = value -> value
        _other -> %{}
      end

    parameters = Map.delete(parameters, "generation_config")

    {generation_config_entries, payload_entries} =
      Enum.split_with(parameters, fn {key, _value} ->
        MapSet.member?(@generation_config_keys, key)
      end)

    generation_config =
      configured_generation_config
      |> Map.merge(Map.new(generation_config_entries))
      |> normalize_max_tokens()

    {Map.new(payload_entries), generation_config}
  end

  defp normalize_max_tokens(%{"max_tokens" => value} = generation_config) do
    generation_config
    |> Map.delete("max_tokens")
    |> Map.put_new("max_output_tokens", value)
  end

  defp normalize_max_tokens(generation_config), do: generation_config

  defp maybe_put_system_instruction(payload, nil), do: payload
  defp maybe_put_system_instruction(payload, ""), do: payload

  defp maybe_put_system_instruction(payload, system_instruction) do
    system_instruction =
      system_instruction
      |> to_string()
      |> String.trim()

    if system_instruction == "" do
      payload
    else
      Map.put(payload, "system_instruction", system_instruction)
    end
  end

  defp maybe_put_generation_config(payload, generation_config) when is_map(generation_config) do
    if map_size(generation_config) == 0 do
      payload
    else
      Map.put(payload, "generation_config", generation_config)
    end
  end

  defp maybe_put_generation_config(payload, _generation_config), do: payload

  defp maybe_put_tools(payload, tools) when is_map(payload) do
    {payload, configured_tools} = pop_configured_tools(payload)
    merged = dedupe_tools(configured_tools ++ google_tools(tools))

    if merged == [] do
      payload
    else
      Map.put(payload, "tools", merged)
    end
  end

  defp pop_configured_tools(payload) when is_map(payload) do
    tools =
      payload
      |> Map.get("tools")
      |> case do
        value when is_list(value) -> value
        _other -> []
      end
      |> google_tools()

    {Map.delete(payload, "tools"), tools}
  end

  defp normalize_tool(tool) when is_map(tool) do
    tool = RequestPayload.stringify_keys(tool)

    case {Map.get(tool, "type"), Map.get(tool, "function")} do
      {"function", %{} = function} ->
        function_tool(function)

      {"function", _function} ->
        function_tool(tool)

      {type, _function} when is_binary(type) and type != "" ->
        [Map.put(tool, "type", type)]

      _other ->
        []
    end
  end

  defp function_tool(function) when is_map(function) do
    function = RequestPayload.stringify_keys(function)
    name = function |> Map.get("name") |> to_string() |> String.trim()

    if name == "" do
      []
    else
      [
        %{
          "type" => "function",
          "name" => name,
          "description" => function |> Map.get("description", "") |> to_string(),
          "parameters" =>
            case Map.get(function, "parameters") do
              %{} = parameters -> parameters
              _other -> %{"type" => "object", "properties" => %{}}
            end
        }
      ]
    end
  end

  defp dedupe_tools(tools) when is_list(tools) do
    {tools, _seen_functions, _seen_provider_tools} =
      Enum.reduce(tools, {[], MapSet.new(), MapSet.new()}, fn
        %{} = tool, {tools, seen_functions, seen_provider_tools} ->
          function_name = function_tool_name(tool)

          cond do
            function_name != "" and MapSet.member?(seen_functions, function_name) ->
              {tools, seen_functions, seen_provider_tools}

            function_name != "" ->
              {tools ++ [tool], MapSet.put(seen_functions, function_name), seen_provider_tools}

            MapSet.member?(seen_provider_tools, tool) ->
              {tools, seen_functions, seen_provider_tools}

            true ->
              {tools ++ [tool], seen_functions, MapSet.put(seen_provider_tools, tool)}
          end

        _tool, acc ->
          acc
      end)

    tools
  end

  defp function_tool_name(tool) when is_map(tool) do
    tool = RequestPayload.stringify_keys(tool)

    if Map.get(tool, "type") == "function" do
      tool
      |> Map.get("name")
      |> to_string()
      |> String.trim()
    else
      ""
    end
  end

  defp normalize_steps(steps) when is_list(steps) do
    steps
    |> Enum.flat_map(fn step ->
      case normalize_step_or_nil(step) do
        %{} = normalized -> [normalized]
        _other -> []
      end
    end)
  end

  defp normalize_steps(%{} = step) do
    case normalize_step_or_nil(step) do
      %{} = normalized -> [normalized]
      _other -> []
    end
  end

  defp normalize_steps(value) when is_binary(value) do
    [%{"type" => "user_input", "content" => [%{"type" => "text", "text" => value}]}]
  end

  defp normalize_steps(_steps), do: []

  defp normalize_step_or_nil(step) when is_map(step) do
    step = RequestPayload.stringify_keys(step)
    type = step |> Map.get("type") |> to_string()

    if MapSet.member?(@step_types, type) do
      step
      |> Map.put("type", type)
      |> sanitize_step(type)
    else
      nil
    end
  end

  defp normalize_step_or_nil(_step), do: nil

  defp sanitize_step(step, "user_input") do
    step
    |> Map.take(["type", "content"])
    |> Map.put("content", normalize_content_list(Map.get(step, "content")))
  end

  defp sanitize_step(step, "model_output") do
    step
    |> Map.take(["type", "content"])
    |> Map.put("content", normalize_content_list(Map.get(step, "content")))
  end

  defp sanitize_step(step, "thought") do
    step
    |> Map.take(["type", "signature", "summary"])
    |> maybe_put_content_list("summary", Map.get(step, "summary"))
  end

  defp sanitize_step(step, "function_call") do
    id = first_present_string([Map.get(step, "id"), Map.get(step, "call_id")])

    step
    |> Map.take(["type", "id", "signature", "name", "arguments"])
    |> Map.put("id", id)
    |> Map.put("arguments", normalize_tool_call_arguments(Map.get(step, "arguments")))
    |> maybe_delete_blank("id")
    |> maybe_delete_blank("name")
  end

  defp sanitize_step(step, "function_result") do
    step
    |> Map.take(["type", "call_id", "name", "result", "is_error"])
    |> maybe_delete_blank("name")
  end

  defp sanitize_step(step, _type), do: step

  defp normalize_content_list(content) when is_list(content) do
    content
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn content ->
      case content_blocks(content, []) do
        [] -> []
        blocks -> blocks
      end
    end)
  end

  defp normalize_content_list(content) when is_binary(content),
    do: content_blocks(content, [])

  defp normalize_content_list(_content), do: []

  defp maybe_put_content_list(step, key, value) do
    content = normalize_content_list(value)

    if content == [] do
      Map.delete(step, key)
    else
      Map.put(step, key, content)
    end
  end

  defp content_kind(content) when is_map(content) do
    content
    |> map_get(:kind, "kind")
    |> case do
      value when value in [:text, "text"] -> :text
      value when value in [:media, "media"] -> :media
      _other -> :other
    end
  end

  defp map_get(map, atom_key, string_key, default \\ nil) when is_map(map) do
    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp maybe_put_non_empty(map, key, value) when is_map(map) do
    value = value |> to_string() |> String.trim()

    if value == "" do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp maybe_delete_blank(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: Map.delete(map, key), else: map

      nil ->
        Map.delete(map, key)

      _other ->
        map
    end
  end

  defp first_present_string(values) when is_list(values) do
    values
    |> Enum.find("", &present?/1)
    |> to_string()
    |> String.trim()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp result_value(%{} = result, key) when is_atom(key) do
    Map.get(result, key, Map.get(result, Atom.to_string(key)))
  end

  defp result_value(_result, _key), do: nil
end
