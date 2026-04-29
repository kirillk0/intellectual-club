defmodule IntellectualClub.Llm.Providers.Common.ChatAdapterHelpers do
  @moduledoc false

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Llm.Providers.Common.TraceHelpers
  alias IntellectualClub.Generation.CacheControl
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Generation.RuntimeTrace

  @opaque_sequence 10_000

  def build_initial_messages(opts) when is_map(opts) do
    history = Map.get(opts, :history, [])
    supports_image_input = Map.get(opts, :supports_image_input, false)
    provider_type = Map.get(opts, :provider_type)
    system_prompt = Map.get(opts, :system_prompt, "")
    cache_control_enabled = Map.get(opts, :cache_control_enabled, false)

    history_messages =
      History.build_chat_completions_history_messages(history,
        supports_image_input: supports_image_input,
        provider_type: provider_type
      )

    messages = prepend_system_prompt(history_messages, system_prompt)
    history_length = length(messages)

    if cache_control_enabled == true do
      messages
      |> CacheControl.apply_system_prompt_marker()
      |> CacheControl.apply_history_end_marker(history_length: history_length)
    else
      messages
    end
  end

  def request_snapshot(%{} = raw_request) do
    messages = RequestPayload.messages(RequestPayload.stringify_keys(raw_request))

    %{
      model_input: messages,
      system_prompt: extract_system_prompt(messages),
      history_length: infer_history_length(messages)
    }
  end

  def request_snapshot(_raw_request),
    do: %{model_input: [], system_prompt: "", history_length: nil}

  def build_followup_messages(opts) when is_map(opts) do
    runtime_step = Map.fetch!(opts, :runtime_step)
    results = Map.get(opts, :results, [])
    raw_request = Map.get(runtime_step, :raw_request) || %{}
    raw_response = Map.get(runtime_step, :raw_response)

    runtime_step = apply_tool_results_to_trace(runtime_step, results)
    previous_messages = RequestPayload.messages(RequestPayload.stringify_keys(raw_request))

    next_messages =
      previous_messages
      |> Kernel.++([assistant_tool_message(raw_response, runtime_step, results)])
      |> Kernel.++(tool_result_messages(results, opts))
      |> maybe_apply_cache_control(opts)

    %{
      messages: next_messages,
      runtime_step: runtime_step
    }
  end

  defp prepend_system_prompt(messages, system_prompt) when is_list(messages) do
    prompt =
      system_prompt
      |> to_string()
      |> String.trim()

    if prompt == "" do
      messages
    else
      [%{"role" => "system", "content" => prompt} | messages]
    end
  end

  defp maybe_apply_cache_control(messages, opts) when is_list(messages) and is_map(opts) do
    cache_control_enabled = Map.get(opts, :cache_control_enabled, false)
    history_length = Map.get(opts, :history_length)

    if cache_control_enabled == true and is_integer(history_length) and history_length >= 0 do
      messages
      |> CacheControl.apply_system_prompt_marker()
      |> CacheControl.apply_history_end_marker(history_length: history_length)
      |> clear_dynamic_cache_markers(history_length)
      |> add_dynamic_cache_marker(history_length)
    else
      messages
    end
  end

  defp maybe_apply_cache_control(messages, _opts), do: messages

  defp clear_dynamic_cache_markers(messages, history_length) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      if index >= history_length do
        CacheControl.remove_cache_control(message)
      else
        message
      end
    end)
  end

  defp add_dynamic_cache_marker(messages, history_length) do
    if length(messages) <= history_length do
      messages
    else
      List.update_at(
        messages,
        length(messages) - 1,
        &CacheControl.add_cache_control_to_last_text_block/1
      )
    end
  end

  defp apply_tool_results_to_trace(%RuntimeTrace.Step{} = runtime_step, results)
       when is_list(results) do
    Enum.reduce(results, runtime_step, fn result, step ->
      key = "tr:" <> to_string(result.call_id)

      opaque = %{
        "tool_call_id" => result.call_id,
        "name" => result.name,
        "raw" => result.result_raw
      }

      step
      |> RuntimeTrace.apply_event({:ensure_item, key, :tool_result, nil})
      |> RuntimeTrace.apply_event({:set_text, key, :tool_result, 1, to_string(result.text || "")})
      |> RuntimeTrace.apply_event({:set_opaque, key, :tool_result, @opaque_sequence, opaque})
      |> TraceHelpers.apply_media_contents_to_trace(
        key,
        :tool_result,
        result.media_contents
      )
      |> TraceHelpers.apply_artifacts_to_trace(result)
    end)
  end

  defp assistant_tool_message(raw_response, runtime_step, results) when is_list(results) do
    assistant_raw = extract_assistant_chat_message(raw_response)

    assistant_content =
      assistant_raw
      |> Map.get("content")
      |> case do
        content when is_binary(content) ->
          content

        content when is_list(content) ->
          content
          |> Enum.map(fn
            %{} = part -> part["text"] || part["content"] || ""
            other -> to_string(other)
          end)
          |> Enum.join("")

        _other ->
          RuntimeTrace.text_for_item_type(runtime_step, :answer)
      end

    message = %{
      "role" => "assistant",
      "content" => to_string(assistant_content || ""),
      "tool_calls" => Enum.map(results, &chat_tool_call_raw/1) |> Enum.reject(&is_nil/1)
    }

    reasoning_details = Map.get(assistant_raw, "reasoning_details")

    cond do
      is_list(reasoning_details) and reasoning_details != [] ->
        Map.put(message, "reasoning_details", sanitize_reasoning_details(reasoning_details))

      true ->
        reasoning_text =
          assistant_raw
          |> Map.get("reasoning", Map.get(assistant_raw, "reasoning_content"))
          |> case do
            value when is_binary(value) ->
              String.trim(value)

            _other ->
              RuntimeTrace.text_for_item_type(runtime_step, :reasoning) |> String.trim()
          end

        if reasoning_text == "" do
          message
        else
          Map.put(message, "reasoning", reasoning_text)
        end
    end
  end

  defp tool_result_messages(results, opts) when is_list(results) and is_map(opts) do
    media_opts = [
      supports_image_input: Map.get(opts, :supports_image_input, false),
      provider_type: Map.get(opts, :provider_type)
    ]

    Enum.flat_map(results, fn result ->
      base_message = %{
        "role" => "tool",
        "tool_call_id" => result.call_id,
        "content" => result.text
      }

      [base_message | Media.media_followup_messages(result.media_contents, media_opts)]
    end)
  end

  defp extract_assistant_chat_message(%{} = raw_response) do
    raw_response
    |> Map.get("choices", [])
    |> case do
      [first | _] when is_map(first) ->
        case Map.get(first, "message") do
          %{} = message -> RequestPayload.stringify_keys(message)
          _other -> %{}
        end

      _other ->
        %{}
    end
  end

  defp extract_assistant_chat_message(_raw_response), do: %{}

  defp sanitize_reasoning_details(value) when not is_list(value), do: value

  defp sanitize_reasoning_details(value) when is_list(value) do
    Enum.map(value, fn
      %{} = item ->
        id = Map.get(item, "id") || Map.get(item, :id)

        if is_binary(id) and String.starts_with?(id, "rs_") do
          Map.delete(RequestPayload.stringify_keys(item), "id")
        else
          RequestPayload.stringify_keys(item)
        end

      other ->
        other
    end)
  end

  defp chat_tool_call_raw(%{call_id: call_id, name: name} = tool_call)
       when is_binary(call_id) and call_id != "" and is_binary(name) and name != "" do
    raw = normalize_tool_call_map(Map.get(tool_call, :raw, %{}))

    arguments =
      tool_call_arguments_text(chat_tool_call_arguments(raw), Map.get(tool_call, :args, %{}))

    %{
      "id" => call_id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => arguments
      }
    }
  end

  defp chat_tool_call_raw(_other), do: nil

  defp chat_tool_call_arguments(%{} = raw) do
    get_in(raw, ["function", "arguments"]) || Map.get(raw, "arguments")
  end

  defp chat_tool_call_arguments(_other), do: nil

  defp tool_call_arguments_text(value, %{} = args) do
    cond do
      is_binary(value) and String.trim(value) != "" ->
        value

      is_map(value) and map_size(value) > 0 ->
        Jason.encode!(value)

      map_size(args) > 0 ->
        Jason.encode!(args)

      true ->
        "{}"
    end
  end

  defp tool_call_arguments_text(value, _args) when is_binary(value) do
    if String.trim(value) != "" do
      value
    else
      "{}"
    end
  end

  defp tool_call_arguments_text(%{} = value, _args), do: Jason.encode!(value)
  defp tool_call_arguments_text(_value, _args), do: "{}"

  defp normalize_tool_call_map(%{} = value) do
    Map.new(value, fn {key, nested} ->
      {to_string(key), normalize_tool_call_value(nested)}
    end)
  end

  defp normalize_tool_call_map(_other), do: %{}

  defp normalize_tool_call_value(%{} = value), do: normalize_tool_call_map(value)

  defp normalize_tool_call_value(list) when is_list(list),
    do: Enum.map(list, &normalize_tool_call_value/1)

  defp normalize_tool_call_value(value), do: value

  defp extract_system_prompt(messages) when is_list(messages) do
    messages
    |> Enum.find_value("", fn
      %{"role" => "system", "content" => content} -> flatten_message_content(content)
      %{role: "system", content: content} -> flatten_message_content(content)
      _other -> nil
    end)
    |> to_string()
  end

  defp extract_system_prompt(_messages), do: ""

  defp infer_history_length(messages) when is_list(messages) do
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

    case drop_system_marker_index(messages, indices) do
      [] ->
        nil

      filtered ->
        Enum.min(filtered) + 1
    end
  end

  defp infer_history_length(_messages), do: nil

  defp drop_system_marker_index(messages, [0 | rest]) do
    case List.first(messages) do
      %{"role" => "system"} -> if(rest == [], do: [0], else: rest)
      %{role: "system"} -> if(rest == [], do: [0], else: rest)
      _other -> [0 | rest]
    end
  end

  defp drop_system_marker_index(_messages, indices), do: indices

  defp message_has_cache_control?(%{} = message) do
    message
    |> Map.get("content", Map.get(message, :content))
    |> case do
      content when is_list(content) ->
        Enum.any?(content, fn
          %{} = part -> is_map(Map.get(part, "cache_control") || Map.get(part, :cache_control))
          _other -> false
        end)

      _other ->
        false
    end
  end

  defp message_has_cache_control?(_message), do: false

  defp flatten_message_content(content) when is_binary(content), do: content

  defp flatten_message_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{} = part ->
        part["text"] || part[:text] || part["content"] || part[:content] || ""

      other ->
        to_string(other)
    end)
    |> Enum.join("")
  end

  defp flatten_message_content(%{} = content) do
    content["text"] || content[:text] || content["content"] || content[:content] || ""
  end

  defp flatten_message_content(other), do: to_string(other)
end
