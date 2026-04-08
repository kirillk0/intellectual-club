defmodule IntellectualClub.LlmCore.OpenRouterChatCompletionTrace do
  @moduledoc """
  Trace-oriented adapter for OpenRouter Chat Completions streaming.

  It translates provider-specific deltas into canonical runtime trace events.
  """

  alias IntellectualClub.LlmCore.OpenRouterChatCompletion

  @type trace_event :: IntellectualClub.Generation.RuntimeTrace.trace_event()

  @type event ::
          {:trace, trace_event()}
          | {:response_complete, map()}
          | {:response_error, map()}

  @spec stream_generate(map(), (event() -> any())) :: :ok
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    emit_old = fn
      {:content_delta, delta, _raw} ->
        emit.({:trace, {:ensure_item, "answer", :answer, nil}})
        emit.({:trace, {:append_text, "answer", :answer, 1, to_string(delta || "")}})

      {:reasoning_delta, delta, _raw} ->
        emit.({:trace, {:ensure_item, "reasoning", :reasoning, 1}})
        emit.({:trace, {:ensure_item, "answer", :answer, 2}})
        emit.({:trace, {:append_text, "reasoning", :reasoning, 1, to_string(delta || "")}})

      {:tool_call_delta, tool_call, _raw} ->
        emit_tool_call_trace(emit, tool_call)

      {:raw_chunk, _obj} ->
        :ok

      {:response_complete, meta} ->
        raw_request = Map.get(meta, :raw_request) || Map.get(meta, "raw_request") || %{}
        raw_response = Map.get(meta, :raw_response) || Map.get(meta, "raw_response")
        usage = Map.get(meta, :usage) || Map.get(meta, "usage")

        emit.({:trace, {:set_step_raw_request, raw_request}})
        emit.({:trace, {:set_step_raw_response, raw_response}})
        emit.({:trace, {:set_step_usage, usage}})
        emit.({:trace, {:set_step_response_final, true}})
        emit.({:response_complete, meta})

      {:response_error, meta} ->
        raw_request = Map.get(meta, :raw_request) || Map.get(meta, "raw_request") || %{}
        raw_response = Map.get(meta, :raw_response) || Map.get(meta, "raw_response")

        emit.({:trace, {:set_step_raw_request, raw_request}})
        emit.({:trace, {:set_step_raw_response, raw_response}})
        emit.({:trace, {:set_step_response_final, false}})
        emit.({:response_error, meta})

      other ->
        emit.(
          {:response_error, %{provider: :openrouter_chat_completion, error_text: inspect(other)}}
        )
    end

    OpenRouterChatCompletion.stream_generate(opts, emit_old)
  end

  defp emit_tool_call_trace(emit, %{call_id: call_id, name: name} = tool_call)
       when is_function(emit, 1) and is_binary(call_id) and call_id != "" and is_binary(name) and
              name != "" do
    arguments =
      case Map.get(tool_call, :arguments) do
        value when is_binary(value) -> value
        value when is_nil(value) -> ""
        value -> to_string(value)
      end

    item_key = "tc:" <> call_id

    text =
      ["Tool call: #{name}", "Call ID: #{call_id}", "Arguments:", arguments]
      |> Enum.join("\n")
      |> String.trim()

    opaque = %{
      "tool_call_id" => call_id,
      "name" => name,
      "arguments" => normalize_tool_call_arguments(arguments),
      "raw" => Map.get(tool_call, :raw)
    }

    emit.({:trace, {:ensure_item, item_key, :tool_call, nil}})
    emit.({:trace, {:set_text, item_key, :tool_call, 1, text}})
    emit.({:trace, {:set_opaque, item_key, :tool_call, 10_000, opaque}})
  end

  defp emit_tool_call_trace(_emit, _tool_call), do: :ok

  defp normalize_tool_call_arguments(value) when is_binary(value) do
    text = String.trim(value)

    cond do
      text == "" ->
        %{}

      true ->
        case Jason.decode(text) do
          {:ok, decoded} -> decoded
          _ -> value
        end
    end
  end

  defp normalize_tool_call_arguments(%{} = value), do: value
  defp normalize_tool_call_arguments(list) when is_list(list), do: list
  defp normalize_tool_call_arguments(nil), do: %{}
  defp normalize_tool_call_arguments(value), do: value
end
