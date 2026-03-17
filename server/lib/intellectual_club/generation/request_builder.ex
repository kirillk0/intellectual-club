defmodule IntellectualClub.Generation.RequestBuilder do
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
      include
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if include == [] do
      payload
    else
      Map.put(payload, "include", include)
    end
  end

  defp maybe_put_include(payload, _other), do: payload

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

  defp maybe_put_responses_tools(payload, tools) when is_map(payload) and is_list(tools) do
    normalized =
      tools
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(fn tool ->
        tool = Map.new(tool)

        case {Map.get(tool, "type"), Map.get(tool, "function")} do
          {"function", %{} = fn_spec} ->
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

          _other ->
            []
        end
      end)

    if normalized == [] do
      payload
    else
      Map.put(payload, "tools", normalized)
    end
  end

  defp maybe_put_responses_tools(payload, _other), do: payload
end
