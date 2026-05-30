defmodule IntellectualClub.Llm.Providers.Common.RequestBuilder do
  @moduledoc """
  Provider-agnostic request payload builders.
  """

  @doc """
  Builds Chat Completions payload.
  """
  def build_chat_completions_payload(model_name, parameters, messages, opts \\ [])
      when is_list(opts) do
    tools = Keyword.get(opts, :tools, [])

    parameters
    |> normalize_parameters()
    |> Map.put("model", model_name)
    |> Map.put("messages", normalize_messages(messages))
    |> Map.put("stream", true)
    |> maybe_put_tools(tools)
  end

  @doc """
  Builds Responses API payload (OpenAI-compatible / openresponses.org spec).
  """
  def build_responses_payload(model_name, parameters, messages, opts \\ [])
      when is_list(opts) do
    include = Keyword.get(opts, :include, [])
    instructions = Keyword.get(opts, :instructions)
    tools = Keyword.get(opts, :tools, [])

    parameters
    |> normalize_parameters()
    |> normalize_responses_parameters()
    |> Map.put("model", model_name)
    |> Map.put("input", normalize_responses_input(messages))
    |> Map.put("stream", true)
    |> Map.put("store", false)
    |> maybe_put_instructions(instructions)
    |> maybe_put_responses_tools(tools)
    |> maybe_put_include(include)
  end

  @doc """
  Builds Responses API payload from a pre-built `input[]` item list.
  """
  def build_responses_payload_from_input_items(model_name, parameters, input_items, opts \\ [])
      when is_list(input_items) and is_list(opts) do
    include = Keyword.get(opts, :include, [])
    instructions = Keyword.get(opts, :instructions)
    tools = Keyword.get(opts, :tools, [])

    parameters
    |> normalize_parameters()
    |> normalize_responses_parameters()
    |> Map.put("model", model_name)
    |> Map.put("input", normalize_responses_items(input_items))
    |> Map.put("stream", true)
    |> Map.put("store", false)
    |> maybe_put_instructions(instructions)
    |> maybe_put_responses_tools(tools)
    |> maybe_put_include(include)
  end

  defp normalize_parameters(nil), do: %{}
  defp normalize_parameters(parameters) when is_map(parameters), do: Map.new(parameters)
  defp normalize_parameters(_other), do: %{}

  defp normalize_messages(messages) when is_list(messages), do: messages
  defp normalize_messages(_other), do: []

  defp normalize_responses_input(messages) when is_list(messages) do
    if responses_items?(messages) do
      normalize_responses_items(messages)
    else
      messages
      |> Enum.flat_map(fn msg ->
        role =
          msg
          |> Map.get("role", Map.get(msg, :role, ""))
          |> to_string()
          |> String.trim()

        content =
          msg
          |> Map.get("content", Map.get(msg, :content, ""))
          |> to_string()

        case role do
          "user" ->
            [
              %{
                "type" => "message",
                "role" => "user",
                "content" => [%{"type" => "input_text", "text" => content}]
              }
            ]

          "assistant" ->
            [
              %{
                "type" => "message",
                "role" => "assistant",
                "status" => "completed",
                "content" => [%{"type" => "output_text", "text" => content, "annotations" => []}]
              }
            ]

          _other ->
            []
        end
      end)
    end
  end

  defp normalize_responses_input(_other), do: []

  defp responses_items?(messages) when is_list(messages) do
    Enum.any?(messages, fn
      %{} = msg ->
        type = Map.get(msg, "type", Map.get(msg, :type))

        is_binary(type) and
          type in ["message", "reasoning", "function_call", "function_call_output"]

      _other ->
        false
    end)
  end

  defp responses_items?(_other), do: false

  defp normalize_responses_items(items) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.new/1)
  end

  defp normalize_responses_items(_other), do: []

  defp normalize_responses_parameters(parameters) when is_map(parameters) do
    cond do
      Map.has_key?(parameters, "max_tokens") ->
        value = Map.get(parameters, "max_tokens")

        parameters
        |> Map.delete("max_tokens")
        |> Map.put("max_output_tokens", value)

      Map.has_key?(parameters, :max_tokens) ->
        value = Map.get(parameters, :max_tokens)

        parameters
        |> Map.delete(:max_tokens)
        |> Map.put("max_output_tokens", value)

      true ->
        parameters
    end
  end

  defp normalize_responses_parameters(other), do: other

  defp maybe_put_include(payload, include) when is_map(payload) and is_list(include) do
    include =
      payload
      |> Map.get("include", Map.get(payload, :include, []))
      |> normalize_include()
      |> Kernel.++(normalize_include(include))
      |> Enum.uniq()

    payload =
      payload
      |> Map.delete("include")
      |> Map.delete(:include)

    if include == [] do
      payload
    else
      Map.put(payload, "include", include)
    end
  end

  defp maybe_put_include(payload, _other), do: payload

  defp normalize_include(include) when is_list(include) do
    include
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_include(_include), do: []

  defp maybe_put_tools(payload, tools) when is_map(payload) and is_list(tools) do
    tools =
      tools
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.new/1)

    if tools == [] do
      payload
    else
      payload
      |> Map.put("tools", tools)
      |> Map.put("tool_choice", "auto")
    end
  end

  defp maybe_put_tools(payload, _other), do: payload

  defp maybe_put_instructions(payload, instructions) when is_map(payload) do
    instructions =
      (instructions || "")
      |> to_string()
      |> String.trim()

    has_instructions? =
      Map.has_key?(payload, "instructions") or Map.has_key?(payload, :instructions)

    if instructions != "" and not has_instructions? do
      Map.put(payload, "instructions", instructions)
    else
      payload
    end
  end

  defp maybe_put_responses_tools(payload, tools) when is_map(payload) do
    {payload, configured_tools} = pop_responses_tools(payload)
    {requested_provider_tools, generated_tools} = split_requested_responses_tools(tools)
    merged = merge_responses_tools(configured_tools ++ requested_provider_tools, generated_tools)

    if merged == [] do
      payload
    else
      Map.put(payload, "tools", merged)
    end
  end

  defp pop_responses_tools(payload) when is_map(payload) do
    tools =
      payload
      |> Map.get("tools", Map.get(payload, :tools, []))
      |> normalize_configured_responses_tools()

    payload =
      payload
      |> Map.delete("tools")
      |> Map.delete(:tools)

    {payload, tools}
  end

  defp normalize_configured_responses_tools(tools) when is_list(tools) do
    tools
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&normalize_configured_responses_tool/1)
  end

  defp normalize_configured_responses_tools(_tools), do: []

  defp normalize_configured_responses_tool(tool) when is_map(tool) do
    tool = stringify_keys(tool)
    type = tool |> Map.get("type") |> to_string() |> String.trim()
    name = tool |> Map.get("name") |> to_string() |> String.trim()

    cond do
      type == "" ->
        []

      type == "function" and name != "" ->
        [Map.put(tool, "name", name)]

      type == "function" and is_map(Map.get(tool, "function")) ->
        normalize_generated_responses_function(Map.get(tool, "function"))

      type == "function" ->
        []

      true ->
        [Map.put(tool, "type", type)]
    end
  end

  defp split_requested_responses_tools(tools) when is_list(tools) do
    Enum.reduce(tools, {[], []}, fn
      tool, {provider_acc, generated_acc} when is_map(tool) ->
        tool = stringify_keys(tool)

        case {Map.get(tool, "type"), Map.get(tool, "function")} do
          {"function", %{} = fn_spec} ->
            {provider_acc, generated_acc ++ normalize_generated_responses_function(fn_spec)}

          _other ->
            {provider_acc ++ normalize_configured_responses_tool(tool), generated_acc}
        end

      _other, acc ->
        acc
    end)
  end

  defp split_requested_responses_tools(_tools), do: {[], []}

  defp normalize_generated_responses_function(fn_spec) when is_map(fn_spec) do
    fn_spec = stringify_keys(fn_spec)
    name = fn_spec |> Map.get("name") |> to_string() |> String.trim()

    if name == "" do
      []
    else
      description = fn_spec |> Map.get("description") |> to_string()

      parameters =
        case Map.get(fn_spec, "parameters") do
          %{} = schema -> schema
          _ -> %{"type" => "object", "properties" => %{}}
        end

      [
        %{
          "type" => "function",
          "name" => name,
          "description" => description,
          "parameters" => parameters,
          "strict" => nil
        }
      ]
    end
  end

  defp normalize_generated_responses_function(_fn_spec), do: []

  defp merge_responses_tools(configured_tools, generated_tools)
       when is_list(configured_tools) and is_list(generated_tools) do
    generated_function_names =
      generated_tools
      |> Enum.map(&responses_tool_function_name/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    configured_tools =
      Enum.reject(configured_tools, fn tool ->
        function_name = responses_tool_function_name(tool)
        function_name != "" and MapSet.member?(generated_function_names, function_name)
      end)

    {tools, _function_names, _provider_tools} =
      Enum.reduce(configured_tools ++ generated_tools, {[], MapSet.new(), MapSet.new()}, fn
        tool, {tools, function_names, provider_tools} when is_map(tool) ->
          function_name = responses_tool_function_name(tool)

          cond do
            function_name != "" and MapSet.member?(function_names, function_name) ->
              {tools, function_names, provider_tools}

            function_name != "" ->
              {tools ++ [tool], MapSet.put(function_names, function_name), provider_tools}

            MapSet.member?(provider_tools, tool) ->
              {tools, function_names, provider_tools}

            true ->
              {tools ++ [tool], function_names, MapSet.put(provider_tools, tool)}
          end

        _tool, acc ->
          acc
      end)

    tools
  end

  defp responses_tool_function_name(%{} = tool) do
    tool = stringify_keys(tool)
    type = tool |> Map.get("type") |> to_string() |> String.trim()

    if type == "function" do
      tool
      |> Map.get("name")
      |> to_string()
      |> String.trim()
    else
      ""
    end
  end

  defp responses_tool_function_name(_tool), do: ""

  defp stringify_keys(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_keys(nested_value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
