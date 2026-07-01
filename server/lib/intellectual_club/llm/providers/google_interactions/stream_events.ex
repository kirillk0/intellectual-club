defmodule IntellectualClub.Llm.Providers.GoogleInteractions.StreamEvents do
  @moduledoc """
  Google Interactions API streaming event reducer.
  """

  alias IntellectualClub.Llm.Providers.GoogleInteractions.Payload

  @opaque_sequence 10_000
  @retryable_http_status_codes MapSet.new([429, 502, 503])
  @retryable_error_codes MapSet.new([
                           "resource_exhausted",
                           "unavailable",
                           "deadline_exceeded",
                           "internal",
                           "rate_limit_exceeded",
                           "server_is_overloaded"
                         ])

  @type trace_event :: IntellectualClub.Generation.RuntimeTrace.trace_event()

  @type event ::
          {:trace, trace_event()}
          | {:response_complete, map()}
          | {:response_error, map()}

  @spec new_state() :: map()
  def new_state do
    %{
      buffer: "",
      current_event: nil,
      data_lines: [],
      steps_by_index: %{},
      updated_indexes: MapSet.new(),
      done?: false
    }
  end

  @spec handle_event(map(), map(), map(), (event() -> any())) :: map()
  def handle_event(state, %{"event_type" => "error"} = obj, raw_request, emit) do
    error = Map.get(obj, "error") || %{}

    emit.(
      {:response_error,
       %{
         provider: :google_interactions,
         status_code: provider_error_status_code(error),
         url: nil,
         retryable: retryable_provider_error_payload?(error),
         error_kind: "provider",
         error_text: provider_error_text(error, "Provider error"),
         raw_request: raw_request,
         raw_response: obj
       }}
    )

    %{state | done?: true}
  end

  def handle_event(state, %{"event_type" => "step.start"} = obj, _raw_request, emit) do
    index = Map.get(obj, "index")
    step = Map.get(obj, "step")

    if is_integer(index) and is_map(step) do
      step = normalize_step(step)
      item_key = item_key(index, step)
      item_type = canonical_item_type(step)

      emit.({:trace, {:ensure_item, item_key, item_type, index + 1}})
      emit_step_final_contents(index, step, emit)

      state
      |> put_step(index, step)
      |> mark_updated(index)
    else
      state
    end
  end

  def handle_event(state, %{"event_type" => "step.delta"} = obj, _raw_request, emit) do
    index = Map.get(obj, "index")
    delta = Map.get(obj, "delta")

    if is_integer(index) and is_map(delta) do
      handle_step_delta(state, index, delta, emit)
    else
      state
    end
  end

  def handle_event(state, %{"event_type" => "step.stop"} = obj, _raw_request, emit) do
    index = Map.get(obj, "index")

    if is_integer(index) do
      step = state |> Map.get(:steps_by_index, %{}) |> Map.get(index, %{"type" => "model_output"})
      emit_step_final_contents(index, step, emit)
      state
    else
      state
    end
  end

  def handle_event(state, %{"event_type" => "interaction.completed"} = obj, raw_request, emit) do
    interaction =
      obj
      |> Map.get("interaction")
      |> case do
        %{} = interaction -> interaction
        _other -> %{}
      end
      |> hydrate_interaction_steps(state)

    status = interaction |> Map.get("status") |> to_string()

    if status in ["failed", "cancelled", "budget_exceeded"] do
      emit.(
        {:response_error,
         %{
           provider: :google_interactions,
           status_code: nil,
           url: nil,
           retryable: false,
           error_kind: "provider",
           error_text: "Interaction finished with status #{status}.",
           raw_request: raw_request,
           raw_response: interaction
         }}
      )
    else
      emit_completed_response(interaction, raw_request, emit)
    end

    %{state | done?: true}
  end

  def handle_event(state, %{"event_type" => "interaction.failed"} = obj, raw_request, emit) do
    interaction = Map.get(obj, "interaction") || %{}

    emit.(
      {:response_error,
       %{
         provider: :google_interactions,
         status_code: nil,
         url: nil,
         retryable: false,
         error_kind: "provider",
         error_text: "Interaction failed.",
         raw_request: raw_request,
         raw_response: interaction
       }}
    )

    %{state | done?: true}
  end

  def handle_event(state, _obj, _raw_request, _emit), do: state

  @spec emit_completed_response(map(), map(), (event() -> any())) :: :ok
  def emit_completed_response(response, raw_request, emit)
      when is_map(response) and is_map(raw_request) and is_function(emit, 1) do
    response = normalize_response(response)
    usage = normalize_usage(Map.get(response, "usage"))

    emit_step_snapshot_from_response(response, emit)
    emit.({:trace, {:set_step_raw_request, raw_request}})
    emit.({:trace, {:set_step_raw_response, response}})
    emit.({:trace, {:set_step_usage, usage}})
    emit.({:trace, {:set_step_response_final, true}})

    emit.(
      {:response_complete,
       %{
         provider: :google_interactions,
         raw_request: raw_request,
         raw_response: response,
         usage: usage
       }}
    )

    :ok
  end

  defp handle_step_delta(state, index, %{"type" => "text", "text" => text}, emit)
       when is_binary(text) do
    step =
      state
      |> step_for_index(index, "model_output")
      |> append_text_content(text)

    item_key = item_key(index, step)
    emit.({:trace, {:ensure_item, item_key, :answer, index + 1}})
    emit.({:trace, {:append_text, item_key, :answer, 1, text}})

    state
    |> put_step(index, step)
    |> mark_updated(index)
  end

  defp handle_step_delta(state, index, %{"type" => "thought_signature"} = delta, emit) do
    signature = Map.get(delta, "signature")

    step =
      state
      |> step_for_index(index, "thought")
      |> maybe_put_non_empty("signature", signature)

    item_key = item_key(index, step)

    emit.({:trace, {:ensure_item, item_key, :reasoning, index + 1}})
    emit.({:trace, {:set_opaque, item_key, :reasoning, @opaque_sequence, opaque_step(step)}})

    state
    |> put_step(index, step)
    |> mark_updated(index)
  end

  defp handle_step_delta(
         state,
         index,
         %{"type" => "thought_summary", "content" => %{} = content},
         emit
       ) do
    text = content_text(content)

    step =
      state
      |> step_for_index(index, "thought")
      |> append_summary_content(content)

    item_key = item_key(index, step)
    emit.({:trace, {:ensure_item, item_key, :reasoning, index + 1}})

    if text != "" do
      emit.({:trace, {:append_text, item_key, :reasoning, 1, text}})
    end

    emit.({:trace, {:set_opaque, item_key, :reasoning, @opaque_sequence, opaque_step(step)}})

    state
    |> put_step(index, step)
    |> mark_updated(index)
  end

  defp handle_step_delta(state, index, %{"type" => "arguments_delta"} = delta, emit) do
    arguments = Map.get(delta, "arguments") |> to_string()

    step =
      state
      |> step_for_index(index, "function_call")
      |> append_arguments(arguments)

    emit_function_call_trace(index, step, emit)

    state
    |> put_step(index, step)
    |> mark_updated(index)
  end

  defp handle_step_delta(state, index, delta, emit) do
    step =
      state
      |> step_for_index(index, infer_step_type(delta))
      |> append_delta_payload(delta)

    item_key = item_key(index, step)
    item_type = canonical_item_type(step)

    emit.({:trace, {:ensure_item, item_key, item_type, index + 1}})
    emit.({:trace, {:set_opaque, item_key, item_type, @opaque_sequence, opaque_step(step)}})

    state
    |> put_step(index, step)
    |> mark_updated(index)
  end

  defp emit_step_snapshot_from_response(response, emit) when is_map(response) do
    response
    |> Map.get("steps", [])
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.each(fn {step, index} ->
      if is_map(step) do
        emit_step_final_contents(index, normalize_step(step), emit)
      end
    end)
  end

  defp emit_step_final_contents(index, step, emit) when is_map(step) do
    step = normalize_step(step)
    item_key = item_key(index, step)

    case canonical_item_type(step) do
      :answer ->
        text = step |> Map.get("content", []) |> text_from_content_list()
        emit.({:trace, {:ensure_item, item_key, :answer, index + 1}})

        if text != "" do
          emit.({:trace, {:set_text, item_key, :answer, 1, text}})
        end

      :reasoning ->
        text = step |> Map.get("summary", []) |> text_from_content_list()
        emit.({:trace, {:ensure_item, item_key, :reasoning, index + 1}})

        if text != "" do
          emit.({:trace, {:set_text, item_key, :reasoning, 1, text}})
        end

        emit.({:trace, {:set_opaque, item_key, :reasoning, @opaque_sequence, opaque_step(step)}})

      :tool_call ->
        emit_function_call_trace(index, step, emit)

      :tool_result ->
        text = step |> Map.get("result") |> result_text()
        emit.({:trace, {:ensure_item, item_key, :tool_result, index + 1}})

        if text != "" do
          emit.({:trace, {:set_text, item_key, :tool_result, 1, text}})
        end

        emit.(
          {:trace, {:set_opaque, item_key, :tool_result, @opaque_sequence, opaque_step(step)}}
        )

      item_type ->
        emit.({:trace, {:ensure_item, item_key, item_type, index + 1}})
        emit.({:trace, {:set_opaque, item_key, item_type, @opaque_sequence, opaque_step(step)}})
    end
  end

  defp emit_function_call_trace(index, step, emit) when is_map(step) do
    item_key = item_key(index, step)
    call_id = step |> Map.get("id") |> to_string() |> String.trim()
    name = step |> Map.get("name") |> to_string() |> String.trim()
    arguments = Map.get(step, "arguments") || %{}
    arguments_text = arguments_text(arguments)

    text =
      ["Tool call: #{name}", "Call ID: #{call_id}", "Arguments:", arguments_text]
      |> Enum.join("\n")
      |> String.trim()

    opaque =
      step
      |> opaque_step()
      |> Map.merge(%{
        "tool_call_id" => call_id,
        "call_id" => call_id,
        "name" => name,
        "arguments" => Payload.normalize_tool_call_arguments(arguments),
        "raw" => step
      })

    emit.({:trace, {:ensure_item, item_key, :tool_call, index + 1}})
    emit.({:trace, {:set_text, item_key, :tool_call, 1, text}})
    emit.({:trace, {:set_opaque, item_key, :tool_call, @opaque_sequence, opaque}})
  end

  defp normalize_response(response) when is_map(response) do
    response
    |> stringify_keys()
    |> Map.update("steps", [], &Payload.response_steps(%{"steps" => &1}))
  end

  defp hydrate_interaction_steps(interaction, state) when is_map(interaction) and is_map(state) do
    interaction = normalize_response(interaction)
    existing_steps = Map.get(interaction, "steps")

    if is_list(existing_steps) and existing_steps != [] do
      interaction
    else
      Map.put(interaction, "steps", assembled_steps(state))
    end
  end

  defp assembled_steps(state) when is_map(state) do
    state
    |> Map.get(:steps_by_index, %{})
    |> Enum.sort_by(fn {index, _step} -> index end)
    |> Enum.map(fn {_index, step} -> normalize_step(step) end)
    |> Enum.filter(&(is_map(&1) and map_size(&1) > 0))
  end

  defp put_step(state, index, step) when is_map(state) and is_integer(index) and is_map(step) do
    %{state | steps_by_index: Map.put(state.steps_by_index, index, normalize_step(step))}
  end

  defp mark_updated(state, index) when is_map(state) and is_integer(index) do
    %{state | updated_indexes: MapSet.put(state.updated_indexes, index)}
  end

  defp step_for_index(state, index, fallback_type) when is_map(state) and is_integer(index) do
    state
    |> Map.get(:steps_by_index, %{})
    |> Map.get(index, %{"type" => fallback_type})
    |> normalize_step()
  end

  defp normalize_step(step) when is_map(step) do
    case Payload.response_steps(%{"steps" => [step]}) do
      [normalized] -> normalized
      [] -> stringify_keys(step)
    end
  end

  defp append_text_content(step, text) when is_map(step) and is_binary(text) do
    Map.update(step, "content", [%{"type" => "text", "text" => text}], fn
      [%{"type" => "text", "text" => existing} | rest] ->
        [%{"type" => "text", "text" => to_string(existing || "") <> text} | rest]

      list when is_list(list) ->
        list ++ [%{"type" => "text", "text" => text}]

      _other ->
        [%{"type" => "text", "text" => text}]
    end)
  end

  defp append_summary_content(step, content) when is_map(step) and is_map(content) do
    content = stringify_keys(content)

    Map.update(step, "summary", [content], fn
      list when is_list(list) -> list ++ [content]
      _other -> [content]
    end)
  end

  defp append_arguments(step, arguments) when is_map(step) do
    existing = Map.get(step, "arguments")
    existing_text = if is_binary(existing), do: existing, else: ""
    Map.put(step, "arguments", existing_text <> to_string(arguments || ""))
  end

  defp append_delta_payload(step, delta) when is_map(step) and is_map(delta) do
    deltas =
      step
      |> Map.get("deltas", [])
      |> case do
        list when is_list(list) -> list
        _other -> []
      end

    Map.put(step, "deltas", deltas ++ [stringify_keys(delta)])
  end

  defp item_key(_index, %{"type" => "function_call", "id" => id})
       when is_binary(id) and id != "" do
    "fc:" <> id
  end

  defp item_key(index, %{"type" => "function_result", "call_id" => call_id})
       when is_binary(call_id) and call_id != "" do
    "fr:" <> call_id <> ":" <> Integer.to_string(index)
  end

  defp item_key(index, %{"type" => type}) when is_binary(type) do
    "step:" <> Integer.to_string(index) <> ":" <> type
  end

  defp item_key(index, _step), do: "step:" <> Integer.to_string(index)

  defp canonical_item_type(%{"type" => "model_output"}), do: :answer
  defp canonical_item_type(%{"type" => "thought"}), do: :reasoning
  defp canonical_item_type(%{"type" => "function_call"}), do: :tool_call
  defp canonical_item_type(%{"type" => "function_result"}), do: :tool_result
  defp canonical_item_type(%{"type" => "user_input"}), do: :input
  defp canonical_item_type(_step), do: :other

  defp infer_step_type(%{"type" => "text"}), do: "model_output"
  defp infer_step_type(%{"type" => "thought_signature"}), do: "thought"
  defp infer_step_type(%{"type" => "thought_summary"}), do: "thought"
  defp infer_step_type(%{"type" => "arguments_delta"}), do: "function_call"
  defp infer_step_type(_delta), do: "model_output"

  defp opaque_step(step) when is_map(step) do
    %{"google_interaction_step" => normalize_step(step)}
  end

  defp normalize_usage(usage) when is_map(usage) do
    usage = stringify_keys(usage)
    reasoning_tokens = coerce_int(Map.get(usage, "total_thought_tokens"))

    %{
      input_tokens: coerce_int(Map.get(usage, "total_input_tokens")),
      output_tokens:
        sum_present_ints([
          Map.get(usage, "total_output_tokens"),
          reasoning_tokens
        ]),
      cached_input_tokens: coerce_int(Map.get(usage, "total_cached_tokens")),
      reasoning_tokens: reasoning_tokens,
      google: usage
    }
  end

  defp normalize_usage(_usage), do: nil

  defp sum_present_ints(values) when is_list(values) do
    values = values |> Enum.map(&coerce_int/1) |> Enum.reject(&is_nil/1)
    if values == [], do: nil, else: Enum.sum(values)
  end

  defp text_from_content_list(contents) when is_list(contents) do
    contents
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
  end

  defp text_from_content_list(_contents), do: ""

  defp content_text(%{} = content) do
    case stringify_keys(content) do
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _other -> ""
    end
  end

  defp content_text(_content), do: ""

  defp result_text(result) when is_binary(result), do: result

  defp result_text(result) when is_map(result) do
    case stringify_keys(result) do
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      map -> Jason.encode!(map)
    end
  end

  defp result_text(result) when is_list(result), do: text_from_content_list(result)
  defp result_text(nil), do: ""
  defp result_text(result), do: to_string(result)

  defp arguments_text(arguments) when is_binary(arguments), do: arguments
  defp arguments_text(arguments) when is_map(arguments), do: Jason.encode!(arguments)
  defp arguments_text(arguments), do: to_string(arguments || "{}")

  defp maybe_put_non_empty(map, key, value) when is_map(map) do
    value = value |> to_string() |> String.trim()

    if value == "" do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp provider_error_text(%{"message" => message}, _fallback)
       when is_binary(message) and message != "" do
    message
  end

  defp provider_error_text(%{message: message}, fallback),
    do: provider_error_text(%{"message" => message}, fallback)

  defp provider_error_text(error, _fallback) when is_binary(error) and error != "", do: error
  defp provider_error_text(_error, fallback), do: fallback

  defp provider_error_status_code(error) when is_map(error) do
    error
    |> stringify_keys()
    |> Map.get("code")
    |> coerce_int()
  end

  defp provider_error_status_code(_error), do: nil

  defp retryable_provider_error_payload?(error) when is_map(error) do
    error = stringify_keys(error)
    status_code = provider_error_status_code(error)

    code =
      error
      |> Map.get("code")
      |> to_string()
      |> String.downcase()

    status =
      error
      |> Map.get("status")
      |> to_string()
      |> String.downcase()

    message =
      error
      |> Map.get("message")
      |> to_string()

    (is_integer(status_code) and MapSet.member?(@retryable_http_status_codes, status_code)) or
      MapSet.member?(@retryable_error_codes, code) or
      MapSet.member?(@retryable_error_codes, status) or
      retryable_provider_message?(message)
  end

  defp retryable_provider_error_payload?(_error), do: false

  defp retryable_provider_message?(message) when is_binary(message) do
    text = message |> String.trim() |> String.downcase()

    text != "" and
      (String.contains?(text, "high demand") or
         String.contains?(text, "try again later") or
         String.contains?(text, "temporarily unavailable") or
         String.contains?(text, "overloaded") or
         String.contains?(text, "rate limit") or
         String.contains?(text, "rate-limited"))
  end

  defp coerce_int(nil), do: nil
  defp coerce_int(value) when is_boolean(value), do: nil
  defp coerce_int(value) when is_integer(value), do: value
  defp coerce_int(value) when is_float(value), do: trunc(value)

  defp coerce_int(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      case Integer.parse(value) do
        {int, ""} -> int
        _other -> nil
      end
    end
  end

  defp coerce_int(_value), do: nil

  defp stringify_keys(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_keys(nested_value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
