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
end
