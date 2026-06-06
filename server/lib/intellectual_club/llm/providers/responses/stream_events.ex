defmodule IntellectualClub.Llm.Providers.Responses.StreamEvents do
  @moduledoc """
  Shared Responses API streaming event reducer.
  """

  @opaque_sequence 10_000
  @raw_reasoning_offset 1_000
  @retryable_http_status_codes MapSet.new([429, 502, 503])
  @retryable_provider_error_codes MapSet.new([
                                    "server_is_overloaded",
                                    "rate_limit_exceeded",
                                    "rate_limited",
                                    "temporarily_unavailable",
                                    "previous_response_not_found",
                                    "websocket_connection_limit_reached"
                                  ])
  @retryable_provider_error_types MapSet.new([
                                    "service_unavailable_error",
                                    "rate_limit_error"
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
      output_items: %{},
      output_item_updates: MapSet.new(),
      tool_calls: %{},
      done?: false
    }
  end

  @spec handle_event(map(), map(), map(), (event() -> any())) :: map()
  def handle_event(state, %{"type" => "error"} = obj, raw_request, emit) do
    error = Map.get(obj, "error") || %{}
    error_text = provider_error_text(error, "Provider error")

    emit.(
      {:response_error,
       %{
         provider: :responses,
         status_code: provider_error_status_code(error),
         url: nil,
         retryable: retryable_provider_error_payload?(error),
         error_kind: "provider",
         error_text: error_text,
         raw_request: raw_request,
         raw_response: obj
       }}
    )

    %{state | done?: true}
  end

  def handle_event(state, %{"type" => "response.failed"} = obj, raw_request, emit) do
    response = Map.get(obj, "response") || %{}
    error = Map.get(response, "error") || %{}
    error_text = provider_error_text(error, "Response failed")

    emit.(
      {:response_error,
       %{
         provider: :responses,
         status_code: provider_error_status_code(error),
         url: nil,
         retryable: retryable_provider_error_payload?(error),
         error_kind: "provider",
         error_text: error_text,
         raw_request: raw_request,
         raw_response: response
       }}
    )

    %{state | done?: true}
  end

  def handle_event(state, %{"type" => "response.completed"} = obj, raw_request, emit) do
    response =
      obj
      |> Map.get("response")
      |> case do
        %{} = response -> hydrate_response_output(response, state)
        _other -> %{}
      end

    _ = emit_step_snapshot_from_response(response, emit)

    usage = Map.get(response, "usage")

    emit.({:trace, {:set_step_raw_response, response}})

    emit.({:trace, {:set_step_usage, usage}})

    emit.({:trace, {:set_step_response_final, true}})

    emit.(
      {:response_complete,
       %{
         provider: :responses,
         raw_request: raw_request,
         raw_response: response,
         usage: usage
       }}
    )

    %{state | done?: true}
  end

  def handle_event(
        state,
        %{"type" => "response.output_item.added"} = obj,
        _raw_request,
        emit
      ) do
    output_index = Map.get(obj, "output_index")
    item = Map.get(obj, "item")

    case {output_index, item} do
      {idx, %{"id" => item_id} = item_map} when is_integer(idx) and is_binary(item_id) ->
        {item_type, _role} = canonical_item_type(item_map)
        emit.({:trace, {:ensure_item, item_id, item_type, idx + 1}})

        state =
          state
          |> put_output_item(idx, item_map)
          |> maybe_store_tool_call_state(item_type, item_id, item_map)

        if item_type in [:tool_call, :tool_result, :reasoning] do
          emit.({:trace, {:set_opaque, item_id, item_type, @opaque_sequence, item_map}})
        end

        state

      _ ->
        state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.output_item.done"} = obj,
        _raw_request,
        emit
      ) do
    output_index = Map.get(obj, "output_index")
    item = Map.get(obj, "item")

    case {output_index, item} do
      {idx, %{"id" => item_id} = item_map} when is_integer(idx) and is_binary(item_id) ->
        {item_type, _role} = canonical_item_type(item_map)
        emit.({:trace, {:ensure_item, item_id, item_type, idx + 1}})

        emit_item_final_contents(item_id, item_type, item_map, emit)
        emit.({:trace, {:set_opaque, item_id, item_type, @opaque_sequence, item_map}})

        state
        |> put_output_item(idx, item_map)
        |> mark_output_item_updated(idx)
        |> maybe_store_tool_call_state(item_type, item_id, item_map)

      _ ->
        state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.output_text.delta"} = obj,
        _raw_request,
        emit
      ) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    content_index = Map.get(obj, "content_index")
    delta = Map.get(obj, "delta")

    if is_binary(item_id) and is_integer(output_index) and is_integer(content_index) and
         is_binary(delta) do
      emit.({:trace, {:ensure_item, item_id, :answer, output_index + 1}})
      emit.({:trace, {:append_text, item_id, :answer, content_index + 1, delta}})

      state =
        update_output_item_text_part(
          state,
          output_index,
          item_id,
          "content",
          content_index,
          "output_text",
          "text",
          delta,
          :append
        )

      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.output_text.done"} = obj,
        _raw_request,
        emit
      ) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    content_index = Map.get(obj, "content_index")
    text = Map.get(obj, "text")

    if is_binary(item_id) and is_integer(output_index) and is_integer(content_index) and
         is_binary(text) do
      emit.({:trace, {:ensure_item, item_id, :answer, output_index + 1}})
      emit.({:trace, {:set_text, item_id, :answer, content_index + 1, text}})

      state =
        update_output_item_text_part(
          state,
          output_index,
          item_id,
          "content",
          content_index,
          "output_text",
          "text",
          text,
          :replace
        )

      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(state, %{"type" => "response.refusal.delta"} = obj, _raw_request, emit) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    content_index = Map.get(obj, "content_index")
    delta = Map.get(obj, "delta")

    if is_binary(item_id) and is_integer(output_index) and is_integer(content_index) and
         is_binary(delta) do
      emit.({:trace, {:ensure_item, item_id, :answer, output_index + 1}})
      emit.({:trace, {:append_text, item_id, :answer, content_index + 1, delta}})

      state =
        update_output_item_text_part(
          state,
          output_index,
          item_id,
          "content",
          content_index,
          "refusal",
          "refusal",
          delta,
          :append
        )

      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(state, %{"type" => "response.refusal.done"} = obj, _raw_request, emit) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    content_index = Map.get(obj, "content_index")
    refusal = Map.get(obj, "refusal")

    if is_binary(item_id) and is_integer(output_index) and is_integer(content_index) and
         is_binary(refusal) do
      emit.({:trace, {:ensure_item, item_id, :answer, output_index + 1}})
      emit.({:trace, {:set_text, item_id, :answer, content_index + 1, refusal}})

      state =
        update_output_item_text_part(
          state,
          output_index,
          item_id,
          "content",
          content_index,
          "refusal",
          "refusal",
          refusal,
          :replace
        )

      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.reasoning_summary_text.delta"} = obj,
        _raw_request,
        emit
      ) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    summary_index = Map.get(obj, "summary_index")
    delta = Map.get(obj, "delta")

    if is_binary(item_id) and is_integer(output_index) and is_integer(summary_index) and
         is_binary(delta) do
      emit.({:trace, {:ensure_item, item_id, :reasoning, output_index + 1}})
      emit.({:trace, {:append_text, item_id, :reasoning, summary_index + 1, delta}})

      state =
        update_output_item_text_part(
          state,
          output_index,
          item_id,
          "summary",
          summary_index,
          "summary_text",
          "text",
          delta,
          :append
        )

      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.reasoning_summary_text.done"} = obj,
        _raw_request,
        emit
      ) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    summary_index = Map.get(obj, "summary_index")
    text = Map.get(obj, "text")

    if is_binary(item_id) and is_integer(output_index) and is_integer(summary_index) and
         is_binary(text) do
      emit.({:trace, {:ensure_item, item_id, :reasoning, output_index + 1}})
      emit.({:trace, {:set_text, item_id, :reasoning, summary_index + 1, text}})

      state =
        update_output_item_text_part(
          state,
          output_index,
          item_id,
          "summary",
          summary_index,
          "summary_text",
          "text",
          text,
          :replace
        )

      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.reasoning.delta"} = obj,
        _raw_request,
        emit
      ) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    content_index = Map.get(obj, "content_index")
    delta = Map.get(obj, "delta")

    if is_binary(item_id) and is_integer(output_index) and is_integer(content_index) and
         is_binary(delta) do
      emit.({:trace, {:ensure_item, item_id, :reasoning, output_index + 1}})

      emit.(
        {:trace,
         {:append_text, item_id, :reasoning, @raw_reasoning_offset + content_index + 1, delta}}
      )

      state =
        update_output_item_text_part(
          state,
          output_index,
          item_id,
          "content",
          content_index,
          "reasoning_text",
          "text",
          delta,
          :append
        )

      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.reasoning.done"} = obj,
        _raw_request,
        emit
      ) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    content_index = Map.get(obj, "content_index")
    text = Map.get(obj, "text")

    if is_binary(item_id) and is_integer(output_index) and is_integer(content_index) and
         is_binary(text) do
      emit.({:trace, {:ensure_item, item_id, :reasoning, output_index + 1}})

      emit.(
        {:trace,
         {:set_text, item_id, :reasoning, @raw_reasoning_offset + content_index + 1, text}}
      )

      state =
        update_output_item_text_part(
          state,
          output_index,
          item_id,
          "content",
          content_index,
          "reasoning_text",
          "text",
          text,
          :replace
        )

      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.function_call_arguments.delta"} = obj,
        _raw_request,
        emit
      ) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    delta = Map.get(obj, "delta")

    if is_binary(item_id) and is_integer(output_index) and is_binary(delta) do
      emit.({:trace, {:ensure_item, item_id, :tool_call, output_index + 1}})
      emit.({:trace, {:append_text, item_id, :tool_call, 1, delta}})

      tool_call =
        state.tool_calls
        |> Map.get(item_id, %{})
        |> Map.update(:arguments, delta, fn existing -> to_string(existing || "") <> delta end)

      state =
        state
        |> Map.put(:tool_calls, Map.put(state.tool_calls, item_id, tool_call))
        |> update_output_item(output_index, item_id, fn item ->
          item
          |> Map.put("type", "function_call")
          |> Map.put("id", item_id)
          |> maybe_put_non_empty("call_id", tool_call.call_id)
          |> maybe_put_non_empty("name", tool_call.name)
          |> Map.put("arguments", to_string(tool_call.arguments || ""))
        end)

      emit.({:trace, {:set_opaque, item_id, :tool_call, @opaque_sequence, tool_call}})
      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(
        state,
        %{"type" => "response.function_call_arguments.done"} = obj,
        _raw_request,
        emit
      ) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    arguments = Map.get(obj, "arguments")

    if is_binary(item_id) and is_integer(output_index) and is_binary(arguments) do
      emit.({:trace, {:ensure_item, item_id, :tool_call, output_index + 1}})
      emit.({:trace, {:set_text, item_id, :tool_call, 1, arguments}})

      tool_call =
        state.tool_calls
        |> Map.get(item_id, %{})
        |> Map.put(:arguments, arguments)

      state =
        state
        |> Map.put(:tool_calls, Map.put(state.tool_calls, item_id, tool_call))
        |> update_output_item(output_index, item_id, fn item ->
          item
          |> Map.put("type", "function_call")
          |> Map.put("id", item_id)
          |> maybe_put_non_empty("call_id", tool_call.call_id)
          |> maybe_put_non_empty("name", tool_call.name)
          |> Map.put("arguments", arguments)
        end)

      emit.({:trace, {:set_opaque, item_id, :tool_call, @opaque_sequence, tool_call}})
      mark_output_item_updated(state, output_index)
    else
      state
    end
  end

  def handle_event(state, _obj, _raw_request, _emit), do: state

  defp emit_step_snapshot_from_response(response, emit) when is_map(response) do
    outputs = Map.get(response, "output") || []

    outputs
    |> Enum.with_index()
    |> Enum.each(fn {item_map, idx} ->
      if is_map(item_map) do
        item_id = Map.get(item_map, "id")

        if is_binary(item_id) do
          {item_type, _role} = canonical_item_type(item_map)
          emit.({:trace, {:ensure_item, item_id, item_type, idx + 1}})
          emit_item_final_contents(item_id, item_type, item_map, emit)

          if item_type in [:tool_call, :tool_result, :reasoning] do
            emit.({:trace, {:set_opaque, item_id, item_type, @opaque_sequence, item_map}})
          end
        end
      end
    end)
  end

  defp emit_item_final_contents(item_id, :answer, %{"type" => "message"} = item_map, emit) do
    (Map.get(item_map, "content") || [])
    |> Enum.with_index()
    |> Enum.each(fn {part, idx} ->
      text = text_from_content_part(part)

      if is_binary(text) do
        emit.({:trace, {:set_text, item_id, :answer, idx + 1, text}})
      else
        emit.({:trace, {:set_opaque, item_id, :answer, @opaque_sequence + idx + 1, part}})
      end
    end)
  end

  defp emit_item_final_contents(item_id, :reasoning, %{"type" => "reasoning"} = item_map, emit) do
    (Map.get(item_map, "summary") || [])
    |> Enum.with_index()
    |> Enum.each(fn {part, idx} ->
      text = text_from_content_part(part)

      if is_binary(text) do
        emit.({:trace, {:set_text, item_id, :reasoning, idx + 1, text}})
      end
    end)

    (Map.get(item_map, "content") || [])
    |> Enum.with_index()
    |> Enum.each(fn {part, idx} ->
      text = text_from_content_part(part)

      if is_binary(text) do
        emit.({:trace, {:set_text, item_id, :reasoning, @raw_reasoning_offset + idx + 1, text}})
      end
    end)
  end

  defp emit_item_final_contents(
         item_id,
         :tool_call,
         %{"type" => "function_call"} = item_map,
         emit
       ) do
    emit.({:trace, {:set_text, item_id, :tool_call, 1, function_call_text(item_map)}})
  end

  defp emit_item_final_contents(
         item_id,
         :tool_result,
         %{"type" => "function_call_output"} = item_map,
         emit
       ) do
    emit.({:trace, {:set_text, item_id, :tool_result, 1, function_call_output_text(item_map)}})
  end

  defp emit_item_final_contents(item_id, item_type, item_map, emit) do
    emit.({:trace, {:set_opaque, item_id, item_type, @opaque_sequence, item_map}})
  end

  defp canonical_item_type(%{"type" => "message"} = item_map) do
    role = item_map |> Map.get("role") |> to_string()

    type =
      case role do
        "assistant" -> :answer
        _ -> :other
      end

    {type, role}
  end

  defp canonical_item_type(%{"type" => "reasoning"}), do: {:reasoning, nil}
  defp canonical_item_type(%{"type" => "function_call"}), do: {:tool_call, nil}
  defp canonical_item_type(%{"type" => "function_call_output"}), do: {:tool_result, nil}
  defp canonical_item_type(_other), do: {:other, nil}

  defp tool_call_state_from_item(item_map) do
    %{
      id: Map.get(item_map, "id"),
      call_id: Map.get(item_map, "call_id"),
      name: Map.get(item_map, "name"),
      arguments: Map.get(item_map, "arguments") || ""
    }
  end

  defp hydrate_response_output(response, state) when is_map(response) and is_map(state) do
    assembled_output = assembled_output_items(state)
    existing_output = Map.get(response, "output")

    cond do
      assembled_output == [] ->
        response

      stream_output_updated?(state) ->
        Map.put(response, "output", merge_completed_output(existing_output, state))

      is_list(existing_output) and existing_output != [] ->
        response

      true ->
        Map.put(response, "output", assembled_output)
    end
  end

  defp hydrate_response_output(response, _state), do: response

  defp assembled_output_items(state) when is_map(state) do
    state
    |> assembled_output_item_entries()
    |> Enum.map(fn {_index, item} -> item end)
  end

  defp assembled_output_items(_state), do: []

  defp assembled_output_item_entries(state) when is_map(state) do
    tool_calls = Map.get(state, :tool_calls, %{})

    state
    |> Map.get(:output_items, %{})
    |> Enum.sort_by(fn {index, _item} -> index end)
    |> Enum.map(fn {index, item} -> {index, finalize_output_item(item, tool_calls)} end)
    |> Enum.filter(fn {_index, item} -> is_map(item) and map_size(item) > 0 end)
  end

  defp assembled_output_item_entries(_state), do: []

  defp stream_output_updated?(state) when is_map(state) do
    state
    |> Map.get(:output_item_updates, MapSet.new())
    |> MapSet.size()
    |> Kernel.>(0)
  end

  defp stream_output_updated?(_state), do: false

  defp merge_completed_output(existing_output, state) when is_map(state) do
    stream_items_by_index =
      state
      |> assembled_output_item_entries()
      |> Map.new()

    existing_items_by_index =
      case existing_output do
        items when is_list(items) ->
          items
          |> Enum.with_index()
          |> Map.new(fn {item, index} -> {index, item} end)

        _other ->
          %{}
      end

    updated_indexes = Map.get(state, :output_item_updates, MapSet.new())

    max_index =
      [
        stream_items_by_index |> Map.keys() |> Enum.max(fn -> -1 end),
        existing_items_by_index |> Map.keys() |> Enum.max(fn -> -1 end)
      ]
      |> Enum.max()

    if max_index < 0 do
      []
    else
      0..max_index
      |> Enum.map(fn index ->
        stream_item = Map.get(stream_items_by_index, index)
        existing_item = Map.get(existing_items_by_index, index)

        cond do
          MapSet.member?(updated_indexes, index) and is_map(stream_item) ->
            merge_output_item_preserving_accumulated(stream_item, existing_item)

          is_map(existing_item) ->
            Map.new(existing_item)

          is_map(stream_item) ->
            stream_item

          true ->
            nil
        end
      end)
      |> Enum.filter(&is_map/1)
    end
  end

  defp merge_completed_output(_existing_output, _state), do: []

  defp finalize_output_item(%{} = item, tool_calls) when is_map(tool_calls) do
    case {Map.get(item, "type"), Map.get(item, "id")} do
      {"function_call", item_id} when is_binary(item_id) ->
        tool_call = Map.get(tool_calls, item_id, %{})

        item
        |> maybe_put_non_empty("call_id", Map.get(tool_call, :call_id))
        |> maybe_put_non_empty("name", Map.get(tool_call, :name))
        |> maybe_put_non_empty("arguments", Map.get(tool_call, :arguments))

      _other ->
        item
    end
  end

  defp finalize_output_item(item, _tool_calls), do: item

  defp maybe_store_tool_call_state(state, :tool_call, item_id, item_map)
       when is_map(state) and is_binary(item_id) and is_map(item_map) do
    tool_call = tool_call_state_from_item(item_map)
    %{state | tool_calls: Map.put(state.tool_calls, item_id, tool_call)}
  end

  defp maybe_store_tool_call_state(state, _item_type, _item_id, _item_map), do: state

  defp put_output_item(state, output_index, item_map)
       when is_map(state) and is_integer(output_index) and is_map(item_map) do
    current = Map.get(state.output_items, output_index, %{})

    %{
      state
      | output_items:
          Map.put(state.output_items, output_index, merge_output_item(current, item_map))
    }
  end

  defp put_output_item(state, _output_index, _item_map), do: state

  defp mark_output_item_updated(state, output_index)
       when is_map(state) and is_integer(output_index) do
    updates =
      state
      |> Map.get(:output_item_updates, MapSet.new())
      |> MapSet.put(output_index)

    %{state | output_item_updates: updates}
  end

  defp mark_output_item_updated(state, _output_index), do: state

  defp merge_output_item(accumulated, incoming) when is_map(accumulated) and is_map(incoming) do
    merge_output_item(accumulated, incoming, :best)
  end

  defp merge_output_item(accumulated, _incoming) when is_map(accumulated),
    do: Map.new(accumulated)

  defp merge_output_item(_accumulated, incoming) when is_map(incoming), do: Map.new(incoming)
  defp merge_output_item(_accumulated, _incoming), do: %{}

  defp merge_output_item_preserving_accumulated(accumulated, incoming)
       when is_map(accumulated) and is_map(incoming) do
    merge_output_item(accumulated, incoming, :accumulated)
  end

  defp merge_output_item_preserving_accumulated(accumulated, _incoming)
       when is_map(accumulated),
       do: Map.new(accumulated)

  defp merge_output_item_preserving_accumulated(_accumulated, incoming)
       when is_map(incoming),
       do: Map.new(incoming)

  defp merge_output_item_preserving_accumulated(_accumulated, _incoming), do: %{}

  defp merge_output_item(accumulated, incoming, string_merge_mode)
       when is_map(accumulated) and is_map(incoming) do
    accumulated = Map.new(accumulated)
    incoming = Map.new(incoming)

    accumulated
    |> Map.merge(incoming)
    |> merge_output_item_container("content", accumulated, incoming, string_merge_mode)
    |> merge_output_item_container("summary", accumulated, incoming, string_merge_mode)
    |> put_merged_string_field("arguments", accumulated, incoming, string_merge_mode)
  end

  defp merge_output_item(accumulated, _incoming, _string_merge_mode) when is_map(accumulated),
    do: Map.new(accumulated)

  defp merge_output_item(_accumulated, incoming, _string_merge_mode) when is_map(incoming),
    do: Map.new(incoming)

  defp merge_output_item(_accumulated, _incoming, _string_merge_mode), do: %{}

  defp merge_output_item_container(item, key, accumulated, incoming, string_merge_mode)
       when is_map(item) and is_binary(key) and is_map(accumulated) and is_map(incoming) do
    accumulated_parts = Map.get(accumulated, key)
    incoming_parts = Map.get(incoming, key)

    cond do
      is_list(accumulated_parts) and is_list(incoming_parts) ->
        Map.put(
          item,
          key,
          merge_content_parts(accumulated_parts, incoming_parts, string_merge_mode)
        )

      is_list(accumulated_parts) and accumulated_parts != [] ->
        Map.put(item, key, accumulated_parts)

      is_list(incoming_parts) ->
        Map.put(item, key, incoming_parts)

      true ->
        item
    end
  end

  defp merge_content_parts(accumulated_parts, incoming_parts, string_merge_mode)
       when is_list(accumulated_parts) and is_list(incoming_parts) do
    max_length = max(length(accumulated_parts), length(incoming_parts))

    if max_length == 0 do
      []
    else
      0..(max_length - 1)
      |> Enum.map(fn index ->
        accumulated = Enum.at(accumulated_parts, index)
        incoming = Enum.at(incoming_parts, index)
        merge_content_part(accumulated, incoming, string_merge_mode)
      end)
      |> Enum.reject(&is_nil/1)
    end
  end

  defp merge_content_part(accumulated, incoming, string_merge_mode)
       when is_map(accumulated) and is_map(incoming) do
    accumulated
    |> Map.merge(incoming)
    |> put_merged_string_field("text", accumulated, incoming, string_merge_mode)
    |> put_merged_string_field("refusal", accumulated, incoming, string_merge_mode)
  end

  defp merge_content_part(accumulated, _incoming, _string_merge_mode) when is_map(accumulated),
    do: Map.new(accumulated)

  defp merge_content_part(_accumulated, incoming, _string_merge_mode) when is_map(incoming),
    do: Map.new(incoming)

  defp merge_content_part(accumulated, _incoming, _string_merge_mode)
       when not is_nil(accumulated),
       do: accumulated

  defp merge_content_part(_accumulated, incoming, _string_merge_mode), do: incoming

  defp put_merged_string_field(map, key, accumulated, incoming, string_merge_mode)
       when is_map(map) and is_binary(key) and is_map(accumulated) and is_map(incoming) do
    accumulated_value = Map.get(accumulated, key)
    incoming_value = Map.get(incoming, key)

    cond do
      non_empty_string?(accumulated_value) and non_empty_string?(incoming_value) ->
        Map.put(
          map,
          key,
          merged_string_value(accumulated_value, incoming_value, string_merge_mode)
        )

      non_empty_string?(accumulated_value) ->
        Map.put(map, key, accumulated_value)

      non_empty_string?(incoming_value) ->
        Map.put(map, key, incoming_value)

      true ->
        map
    end
  end

  defp put_merged_string_field(map, _key, _accumulated, _incoming, _string_merge_mode), do: map

  defp merged_string_value(accumulated_value, _incoming_value, :accumulated),
    do: accumulated_value

  defp merged_string_value(accumulated_value, incoming_value, _mode) do
    if String.length(accumulated_value) >= String.length(incoming_value),
      do: accumulated_value,
      else: incoming_value
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp update_output_item(state, output_index, item_id, fun)
       when is_map(state) and is_integer(output_index) and is_function(fun, 1) do
    current =
      state.output_items
      |> Map.get(output_index, %{})
      |> Map.put_new("id", item_id)

    %{state | output_items: Map.put(state.output_items, output_index, fun.(current))}
  end

  defp update_output_item(state, _output_index, _item_id, _fun), do: state

  defp update_output_item_text_part(
         state,
         output_index,
         item_id,
         container_key,
         content_index,
         part_type,
         text_key,
         text,
         mode
       )
       when is_map(state) and is_integer(output_index) and is_binary(item_id) and
              is_binary(container_key) and is_integer(content_index) and content_index >= 0 and
              is_binary(part_type) and is_binary(text_key) and is_binary(text) do
    update_output_item(state, output_index, item_id, fn item ->
      item
      |> Map.put_new("id", item_id)
      |> maybe_put_default_container_type(container_key)
      |> Map.update(container_key, [text_part(part_type, text_key, text)], fn parts ->
        part =
          parts
          |> Enum.at(content_index, %{})
          |> Map.new()
          |> Map.put("type", part_type)
          |> Map.update(text_key, text, fn existing ->
            existing = to_string(existing || "")

            case mode do
              :append -> existing <> text
              _other -> text
            end
          end)

        list_put(parts, content_index, part)
      end)
    end)
  end

  defp update_output_item_text_part(
         state,
         _output_index,
         _item_id,
         _container_key,
         _content_index,
         _part_type,
         _text_key,
         _text,
         _mode
       ),
       do: state

  defp maybe_put_default_container_type(item, "content"), do: Map.put_new(item, "type", "message")

  defp maybe_put_default_container_type(item, "summary"),
    do: Map.put_new(item, "type", "reasoning")

  defp maybe_put_default_container_type(item, _container_key), do: item

  defp text_part(part_type, text_key, text) do
    %{"type" => part_type, text_key => text}
  end

  defp list_put(list, index, value) when is_list(list) and is_integer(index) and index >= 0 do
    if index < length(list) do
      List.replace_at(list, index, value)
    else
      list ++ List.duplicate(%{}, index - length(list)) ++ [value]
    end
  end

  defp maybe_put_non_empty(map, _key, nil), do: map

  defp maybe_put_non_empty(map, key, value) when is_binary(value) do
    if String.trim(value) == "" do
      map
    else
      existing = Map.get(map, key)

      if is_binary(existing) and String.trim(existing) != "" do
        map
      else
        Map.put(map, key, value)
      end
    end
  end

  defp maybe_put_non_empty(map, key, value), do: Map.put_new(map, key, value)

  defp function_call_text(item_map) do
    name = Map.get(item_map, "name") |> to_string()
    call_id = Map.get(item_map, "call_id") |> to_string()
    arguments = Map.get(item_map, "arguments") |> to_string()

    [
      "Tool call: #{name}",
      "Call ID: #{call_id}",
      "Arguments:",
      arguments
    ]
    |> Enum.join("\n")
    |> String.trim()
  end

  defp function_call_output_text(item_map) do
    output = Map.get(item_map, "output")

    rendered =
      cond do
        is_binary(output) ->
          output

        is_list(output) ->
          output
          |> Enum.map(&text_from_content_part/1)
          |> Enum.filter(&is_binary/1)
          |> Enum.join("")

        true ->
          ""
      end

    rendered =
      if String.trim(rendered) == "" do
        Jason.encode!(%{"output" => output})
      else
        rendered
      end

    String.trim(rendered)
  end

  defp text_from_content_part(part) when is_map(part) do
    type = Map.get(part, "type")

    cond do
      type in ["output_text", "input_text", "text", "summary_text", "reasoning_text"] ->
        Map.get(part, "text")

      type == "refusal" ->
        Map.get(part, "refusal")

      true ->
        nil
    end
  end

  defp text_from_content_part(_other), do: nil

  defp provider_error_text(error, fallback) when is_map(error) and is_binary(fallback) do
    case trimmed_string(Map.get(error, "message") || Map.get(error, :message)) do
      "" -> fallback
      message -> message
    end
  end

  defp provider_error_text(_error, fallback), do: fallback

  defp provider_error_status_code(error) when is_map(error) do
    error
    |> Map.get("code", Map.get(error, :code))
    |> parse_int()
  end

  defp provider_error_status_code(_error), do: nil

  defp retryable_provider_error_payload?(error) when is_map(error) do
    status_code = provider_error_status_code(error)
    code = error_field(error, :code)
    type = error_field(error, :type)
    message = error_field(error, :message)

    (is_integer(status_code) and MapSet.member?(@retryable_http_status_codes, status_code)) or
      MapSet.member?(@retryable_provider_error_codes, code) or
      MapSet.member?(@retryable_provider_error_types, type) or
      retryable_provider_message?(message)
  end

  defp retryable_provider_error_payload?(_error), do: false

  defp retryable_provider_message?(message) when is_binary(message) do
    text = message |> String.trim() |> String.downcase()

    text != "" and
      (String.contains?(text, "overloaded") or
         String.contains?(text, "try again later") or
         String.contains?(text, "rate limit") or
         String.contains?(text, "rate-limited") or
         String.contains?(text, "temporarily unavailable"))
  end

  defp retryable_provider_message?(_message), do: false

  defp error_field(error, key) when is_map(error) and is_atom(key) do
    error
    |> Map.get(key, Map.get(error, Atom.to_string(key)))
    |> trimmed_string()
    |> String.downcase()
  end

  defp error_field(_error, _key), do: ""

  defp trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp trimmed_string(nil), do: ""
  defp trimmed_string(value), do: value |> to_string() |> String.trim()

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp parse_int(_value), do: nil
end
