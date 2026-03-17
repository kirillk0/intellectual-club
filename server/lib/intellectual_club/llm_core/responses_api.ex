defmodule IntellectualClub.LlmCore.ResponsesApi do
  @moduledoc """
  Responses API (OpenAI-compatible) streaming client.

  This implementation follows the Open Responses specification:
  https://www.openresponses.org
  """

  alias IntellectualClub.Generation.RequestBuilder
  alias Req.Response

  @opaque_sequence 10_000
  @raw_reasoning_offset 1_000
  @retryable_http_status_codes MapSet.new([429, 502])

  @type trace_event :: IntellectualClub.Generation.RuntimeTrace.trace_event()

  @type event ::
          {:trace, trace_event()}
          | {:response_complete, map()}
          | {:response_error, map()}

  @spec stream_generate(
          %{
            optional(:base_url) => String.t() | nil,
            required(:api_key) => String.t(),
            optional(:model_name) => String.t() | nil,
            optional(:parameters) => map(),
            optional(:messages) => list(map()),
            optional(:request_payload) => map() | nil,
            optional(:timeout_ms) => non_neg_integer(),
            optional(:connect_timeout_ms) => non_neg_integer()
          },
          (event() -> any())
        ) :: :ok
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    base_url =
      opts
      |> Map.get(:base_url)
      |> default_base_url()

    api_key = Map.fetch!(opts, :api_key)
    timeout_ms = Map.get(opts, :timeout_ms, 300_000)
    connect_timeout_ms = Map.get(opts, :connect_timeout_ms, 10_000)

    url = String.trim_trailing(base_url, "/") <> "/responses"

    payload = build_payload(opts)

    headers = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    request_opts = [
      url: url,
      method: :post,
      headers: headers,
      json: payload,
      connect_options: [timeout: connect_timeout_ms],
      receive_timeout: timeout_ms,
      into: :self
    ]

    try do
      response = Req.request!(request_opts)

      if response.status >= 400 do
        body_text = read_full_text(response)
        response_json = safe_json_decode(body_text)
        raw_response = normalize_raw_response(response_json, body_text)

        emit.(
          {:response_error,
           %{
             provider: :responses,
             status_code: response.status,
             url: url,
             retryable: MapSet.member?(@retryable_http_status_codes, response.status),
             error_kind: "http",
             error_text: extract_error_summary(response_json, body_text),
             raw_request: payload,
             raw_response: raw_response
           }}
        )

        :ok
      else
        stream_responses(response, payload, emit)
      end
    rescue
      exception ->
        retryable = retryable_exception?(exception)

        emit.(
          {:response_error,
           %{
             provider: :responses,
             status_code: nil,
             url: url,
             retryable: retryable,
             error_kind: exception_error_kind(exception),
             error_text: Exception.message(exception),
             raw_request: payload,
             raw_response: nil
           }}
        )

        :ok
    catch
      :exit, reason ->
        retryable = retryable_exit_reason?(reason)

        emit.(
          {:response_error,
           %{
             provider: :responses,
             status_code: nil,
             url: url,
             retryable: retryable,
             error_kind: exit_error_kind(reason),
             error_text: Exception.format_exit(reason),
             raw_request: payload,
             raw_response: nil
           }}
        )

        :ok
    end
  end

  defp default_base_url(nil), do: "https://api.openai.com/v1"
  defp default_base_url(""), do: "https://api.openai.com/v1"
  defp default_base_url(value), do: to_string(value)

  defp build_payload(opts) do
    payload =
      case Map.get(opts, :request_payload) do
        payload when is_map(payload) and map_size(payload) > 0 ->
          payload

        _ ->
          model_name = Map.get(opts, :model_name) || "gpt-4.1-mini"
          parameters = Map.get(opts, :parameters, %{})
          messages = Map.get(opts, :messages, [])

          RequestBuilder.build_responses_payload(model_name, parameters, messages,
            include: ["reasoning.encrypted_content"]
          )
      end

    payload
    |> ensure_store_disabled()
    |> ensure_instructions_present()
  end

  defp ensure_store_disabled(payload) when is_map(payload) do
    payload
    |> Map.delete(:store)
    |> Map.put("store", false)
  end

  defp ensure_store_disabled(payload), do: payload

  defp ensure_instructions_present(payload) when is_map(payload) do
    instructions =
      cond do
        Map.has_key?(payload, "instructions") ->
          normalize_instructions_value(Map.get(payload, "instructions"))

        Map.has_key?(payload, :instructions) ->
          normalize_instructions_value(Map.get(payload, :instructions))

        true ->
          ""
      end

    payload
    |> Map.delete(:instructions)
    |> Map.put("instructions", instructions)
  end

  defp ensure_instructions_present(payload), do: payload

  defp normalize_instructions_value(nil), do: ""
  defp normalize_instructions_value(value) when is_binary(value), do: value

  defp normalize_instructions_value(value) when is_atom(value) or is_number(value),
    do: to_string(value)

  defp normalize_instructions_value(_value), do: ""

  defp stream_responses(%Response{} = response, raw_request, emit) do
    state = %{
      buffer: "",
      current_event: nil,
      data_lines: [],
      tool_calls: %{},
      done?: false
    }

    final_state =
      Enum.reduce_while(response.body, state, fn chunk, state ->
        state = feed_chunk(state, chunk, raw_request, emit)
        if state.done?, do: {:halt, state}, else: {:cont, state}
      end)

    if not final_state.done? do
      emit.(
        {:response_error,
         %{
           provider: :responses,
           status_code: response.status,
           url: nil,
           retryable: true,
           error_kind: "network",
           error_text: "Stream ended without a terminal event",
           raw_request: raw_request,
           raw_response: nil
         }}
      )
    end

    :ok
  end

  defp feed_chunk(state, chunk, raw_request, emit) when is_binary(chunk) do
    buffer = state.buffer <> chunk
    parts = :binary.split(buffer, "\n", [:global])

    {lines, rest} =
      case parts do
        [] -> {[], ""}
        [_only] -> {[], buffer}
        _ -> {Enum.drop(parts, -1), List.last(parts)}
      end

    state = %{state | buffer: rest}

    Enum.reduce(lines, state, fn line, state ->
      line = line |> String.trim_trailing("\r")
      handle_sse_line(state, line, raw_request, emit)
    end)
  end

  defp feed_chunk(state, _chunk, _raw_request, _emit), do: state

  defp handle_sse_line(state, ":" <> _comment, _raw_request, _emit), do: state

  defp handle_sse_line(state, "", raw_request, emit) do
    dispatch_sse_event(state, raw_request, emit)
  end

  defp handle_sse_line(state, line, _raw_request, _emit) when not is_binary(line), do: state

  defp handle_sse_line(state, "event:" <> rest, _raw_request, _emit) do
    %{state | current_event: String.trim(rest)}
  end

  defp handle_sse_line(state, "data:" <> rest, _raw_request, _emit) do
    %{state | data_lines: state.data_lines ++ [String.trim(rest)]}
  end

  defp handle_sse_line(state, _other, _raw_request, _emit), do: state

  defp dispatch_sse_event(%{data_lines: []} = state, _raw_request, _emit) do
    %{state | current_event: nil}
  end

  defp dispatch_sse_event(state, raw_request, emit) do
    data = Enum.join(state.data_lines, "\n") |> String.trim()

    state = %{state | data_lines: [], current_event: nil}

    cond do
      data == "" ->
        state

      data == "[DONE]" ->
        %{state | done?: true}

      true ->
        case safe_json_decode(data) do
          nil ->
            state

          obj ->
            handle_stream_event(state, obj, raw_request, emit)
        end
    end
  end

  defp handle_stream_event(state, %{"type" => "error"} = obj, raw_request, emit) do
    error_text =
      obj
      |> Map.get("error", %{})
      |> Map.get("message")
      |> to_string()
      |> String.trim()

    emit.(
      {:response_error,
       %{
         provider: :responses,
         status_code: nil,
         url: nil,
         retryable: false,
         error_kind: "provider",
         error_text: if(error_text == "", do: "Provider error", else: error_text),
         raw_request: raw_request,
         raw_response: obj
       }}
    )

    %{state | done?: true}
  end

  defp handle_stream_event(state, %{"type" => "response.failed"} = obj, raw_request, emit) do
    response = Map.get(obj, "response") || %{}
    error = Map.get(response, "error") || %{}

    error_text =
      error
      |> Map.get("message")
      |> to_string()
      |> String.trim()

    emit.(
      {:response_error,
       %{
         provider: :responses,
         status_code: nil,
         url: nil,
         retryable: false,
         error_kind: "provider",
         error_text: if(error_text == "", do: "Response failed", else: error_text),
         raw_request: raw_request,
         raw_response: response
       }}
    )

    %{state | done?: true}
  end

  defp handle_stream_event(state, %{"type" => "response.completed"} = obj, raw_request, emit) do
    response = Map.get(obj, "response") || %{}

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

  defp handle_stream_event(
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
          if item_type == :tool_call do
            tool_call = tool_call_state_from_item(item_map)
            %{state | tool_calls: Map.put(state.tool_calls, item_id, tool_call)}
          else
            state
          end

        if item_type in [:tool_call, :tool_result, :reasoning] do
          emit.({:trace, {:set_opaque, item_id, item_type, @opaque_sequence, item_map}})
        end

        state

      _ ->
        state
    end
  end

  defp handle_stream_event(
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

      _ ->
        state
    end
  end

  defp handle_stream_event(
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
    end

    state
  end

  defp handle_stream_event(
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
    end

    state
  end

  defp handle_stream_event(state, %{"type" => "response.refusal.delta"} = obj, _raw_request, emit) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    content_index = Map.get(obj, "content_index")
    delta = Map.get(obj, "delta")

    if is_binary(item_id) and is_integer(output_index) and is_integer(content_index) and
         is_binary(delta) do
      emit.({:trace, {:ensure_item, item_id, :answer, output_index + 1}})
      emit.({:trace, {:append_text, item_id, :answer, content_index + 1, delta}})
    end

    state
  end

  defp handle_stream_event(state, %{"type" => "response.refusal.done"} = obj, _raw_request, emit) do
    item_id = Map.get(obj, "item_id")
    output_index = Map.get(obj, "output_index")
    content_index = Map.get(obj, "content_index")
    refusal = Map.get(obj, "refusal")

    if is_binary(item_id) and is_integer(output_index) and is_integer(content_index) and
         is_binary(refusal) do
      emit.({:trace, {:ensure_item, item_id, :answer, output_index + 1}})
      emit.({:trace, {:set_text, item_id, :answer, content_index + 1, refusal}})
    end

    state
  end

  defp handle_stream_event(
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
    end

    state
  end

  defp handle_stream_event(
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
    end

    state
  end

  defp handle_stream_event(
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
    end

    state
  end

  defp handle_stream_event(
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
    end

    state
  end

  defp handle_stream_event(
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

      state = %{state | tool_calls: Map.put(state.tool_calls, item_id, tool_call)}
      emit.({:trace, {:set_opaque, item_id, :tool_call, @opaque_sequence, tool_call}})
      state
    else
      state
    end
  end

  defp handle_stream_event(
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

      state = %{state | tool_calls: Map.put(state.tool_calls, item_id, tool_call)}
      emit.({:trace, {:set_opaque, item_id, :tool_call, @opaque_sequence, tool_call}})
      state
    else
      state
    end
  end

  defp handle_stream_event(state, _obj, _raw_request, _emit), do: state

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

  defp safe_json_decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp normalize_raw_response(value, fallback_text) do
    cond do
      is_map(value) ->
        value

      is_nil(value) ->
        %{"raw_text" => String.trim(fallback_text || "")}

      true ->
        %{"raw" => value}
    end
  end

  defp read_full_text(%Response{} = response) do
    response.body
    |> Enum.reduce([], fn chunk, acc -> [acc | [chunk]] end)
    |> IO.iodata_to_binary()
  end

  defp extract_error_summary(%{"error" => %{"message" => message}}, _fallback)
       when is_binary(message) and message != "" do
    truncate_text(message, 500)
  end

  defp extract_error_summary(%{"message" => message}, _fallback)
       when is_binary(message) and message != "" do
    truncate_text(message, 500)
  end

  defp extract_error_summary(%{"error" => %{"message" => message}}, fallback)
       when is_binary(fallback) do
    truncate_text(to_string(message || fallback), 500)
  end

  defp extract_error_summary(_json, fallback) when is_binary(fallback) do
    fallback
    |> String.trim()
    |> truncate_text(500)
  end

  defp truncate_text(value, limit) when is_binary(value) and is_integer(limit) and limit > 0 do
    if String.length(value) <= limit do
      value
    else
      String.slice(value, 0, limit) <> "…"
    end
  end

  defp retryable_exception?(exception) do
    timeout_exception?(exception) or transport_exception?(exception)
  end

  defp exception_error_kind(exception) do
    cond do
      timeout_exception?(exception) -> "timeout"
      transport_exception?(exception) -> "network"
      true -> "other"
    end
  end

  defp retryable_exit_reason?(reason) do
    reason_string = reason_to_string(reason)
    String.contains?(reason_string, "timeout") or transport_reason?(reason)
  end

  defp exit_error_kind(reason) do
    reason_string = reason_to_string(reason)

    cond do
      String.contains?(reason_string, "timeout") -> "timeout"
      transport_reason?(reason) -> "network"
      true -> "other"
    end
  end

  defp timeout_exception?(exception) do
    message =
      exception
      |> Exception.message()
      |> String.downcase()

    reason = Map.get(exception, :reason)
    String.contains?(message, "timeout") or reason == :timeout
  end

  defp transport_exception?(exception) do
    module =
      exception.__struct__
      |> to_string()
      |> String.downcase()

    String.contains?(module, "transporterror") or
      String.contains?(module, "connectionerror") or
      transport_reason?(Map.get(exception, :reason))
  end

  defp transport_reason?(reason) when is_atom(reason) do
    reason in [
      :closed,
      :econnrefused,
      :econnreset,
      :enetunreach,
      :ehostunreach,
      :nxdomain
    ]
  end

  defp transport_reason?(reason) do
    reason
    |> reason_to_string()
    |> String.contains?("econn")
  end

  defp reason_to_string(reason) do
    reason
    |> inspect()
    |> String.downcase()
  end
end
