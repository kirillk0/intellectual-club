defmodule IntellectualClub.Llm.Providers.AnthropicMessages.Api do
  @moduledoc """
  Anthropic Messages API streaming client.
  """

  alias IntellectualClub.Llm.Providers.AnthropicMessages.Payload
  alias Req.Response

  @anthropic_version "2023-06-01"
  @opaque_sequence 10_000
  @retryable_http_status_codes MapSet.new([429, 500, 502, 503, 529])
  @retryable_error_types MapSet.new([
                           "api_error",
                           "overloaded_error",
                           "rate_limit_error"
                         ])

  @type trace_event :: IntellectualClub.Generation.RuntimeTrace.trace_event()

  @type event ::
          {:trace, trace_event()}
          | {:response_complete, map()}
          | {:response_error, map()}

  @spec stream_generate(
          %{
            required(:base_url) => String.t(),
            required(:api_key) => String.t(),
            required(:request_payload) => map(),
            optional(:timeout_ms) => non_neg_integer(),
            optional(:connect_timeout_ms) => non_neg_integer()
          },
          (event() -> any())
        ) :: :ok
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    base_url = Map.fetch!(opts, :base_url)
    api_key = Map.fetch!(opts, :api_key)
    payload = Map.get(opts, :request_payload, %{}) || %{}
    timeout_ms = Map.get(opts, :timeout_ms, 300_000)
    connect_timeout_ms = Map.get(opts, :connect_timeout_ms, 10_000)
    url = String.trim_trailing(base_url, "/") <> "/messages"

    headers =
      [
        {"x-api-key", api_key},
        {"anthropic-version", anthropic_version(payload)},
        {"content-type", "application/json"},
        {"accept", "text/event-stream"}
      ]
      |> maybe_put_anthropic_beta(payload)

    request_opts = [
      url: url,
      method: :post,
      headers: headers,
      json: clean_transport_payload(payload),
      connect_options: [timeout: connect_timeout_ms],
      receive_timeout: timeout_ms,
      into: :self,
      retry: false
    ]

    try do
      response = Req.request!(request_opts)

      if response.status >= 400 do
        body_text = read_full_text(response)
        response_json = safe_json_decode(body_text)
        raw_response = normalize_raw_response(response_json, body_text, response.status)

        emit.(
          {:response_error,
           %{
             provider: :anthropic_messages,
             status_code: response.status,
             url: url,
             retryable: MapSet.member?(@retryable_http_status_codes, response.status),
             error_kind: "http",
             error_text: extract_error_summary(response_json, body_text),
             raw_request: clean_transport_payload(payload),
             raw_response: raw_response
           }}
        )

        :ok
      else
        stream_messages(response, clean_transport_payload(payload), url, emit)
      end
    rescue
      exception ->
        retryable = retryable_exception?(exception)

        emit.(
          {:response_error,
           %{
             provider: :anthropic_messages,
             status_code: nil,
             url: url,
             retryable: retryable,
             error_kind: exception_error_kind(exception),
             error_text: Exception.message(exception),
             raw_request: clean_transport_payload(payload),
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
             provider: :anthropic_messages,
             status_code: nil,
             url: url,
             retryable: retryable,
             error_kind: exit_error_kind(reason),
             error_text: Exception.format_exit(reason),
             raw_request: clean_transport_payload(payload),
             raw_response: nil
           }}
        )

        :ok
    end
  end

  defp anthropic_version(%{} = payload) do
    payload
    |> Map.get("anthropic_version", @anthropic_version)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @anthropic_version
      version -> version
    end
  end

  defp clean_transport_payload(%{} = payload) do
    Map.drop(payload, ["anthropic_version", "anthropic_beta"])
  end

  defp maybe_put_anthropic_beta(headers, %{} = payload) when is_list(headers) do
    beta =
      payload
      |> Map.get("anthropic_beta")
      |> normalize_beta_header()

    if beta == "" do
      headers
    else
      headers ++ [{"anthropic-beta", beta}]
    end
  end

  defp normalize_beta_header(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(",")
  end

  defp normalize_beta_header(value) when is_binary(value), do: String.trim(value)
  defp normalize_beta_header(_value), do: ""

  defp stream_messages(%Response{} = response, raw_request, url, emit) do
    state = %{
      buffer: "",
      current_event: nil,
      data_lines: [],
      message: %{},
      content_blocks: %{},
      tool_input_json: %{},
      usage: %{},
      stop_reason: nil,
      done?: false
    }

    final_state =
      Enum.reduce_while(response.body, state, fn chunk, state ->
        state = feed_chunk(state, chunk, raw_request, url, emit)
        if state.done?, do: {:halt, state}, else: {:cont, state}
      end)

    if not final_state.done? do
      emit.(
        {:response_error,
         %{
           provider: :anthropic_messages,
           status_code: response.status,
           url: url,
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

  defp feed_chunk(state, chunk, raw_request, url, emit) when is_binary(chunk) do
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
      handle_sse_line(state, line, raw_request, url, emit)
    end)
  end

  defp feed_chunk(state, _chunk, _raw_request, _url, _emit), do: state

  defp handle_sse_line(state, ":" <> _comment, _raw_request, _url, _emit), do: state

  defp handle_sse_line(state, "", raw_request, url, emit) do
    dispatch_sse_event(state, raw_request, url, emit)
  end

  defp handle_sse_line(state, "event:" <> rest, _raw_request, _url, _emit) do
    %{state | current_event: String.trim(rest)}
  end

  defp handle_sse_line(state, "data:" <> rest, _raw_request, _url, _emit) do
    %{state | data_lines: state.data_lines ++ [String.trim(rest)]}
  end

  defp handle_sse_line(state, _other, _raw_request, _url, _emit), do: state

  defp dispatch_sse_event(%{data_lines: []} = state, _raw_request, _url, _emit) do
    %{state | current_event: nil}
  end

  defp dispatch_sse_event(state, raw_request, url, emit) do
    data = Enum.join(state.data_lines, "\n") |> String.trim()
    state = %{state | data_lines: [], current_event: nil}

    cond do
      data == "" ->
        state

      data == "[DONE]" ->
        %{state | done?: true}

      true ->
        case safe_json_decode(data) do
          nil -> state
          obj -> handle_stream_event(state, obj, raw_request, url, emit)
        end
    end
  end

  defp handle_stream_event(state, %{"type" => "message_start"} = obj, _raw_request, _url, _emit) do
    message = Map.get(obj, "message")
    message = if is_map(message), do: message, else: %{}
    usage = normalize_usage(Map.get(message, "usage"))

    %{
      state
      | message: message,
        usage: merge_usage(state.usage, usage)
    }
  end

  defp handle_stream_event(
         state,
         %{"type" => "content_block_start"} = obj,
         _raw_request,
         _url,
         emit
       ) do
    index = Map.get(obj, "index")
    block = Map.get(obj, "content_block")

    if is_integer(index) and is_map(block) do
      block = Payload.stringify_keys(block)
      state = put_content_block(state, index, block)
      maybe_emit_tool_call(state, index, emit)
    else
      state
    end
  end

  defp handle_stream_event(
         state,
         %{"type" => "content_block_delta"} = obj,
         _raw_request,
         _url,
         emit
       ) do
    index = Map.get(obj, "index")
    delta = Map.get(obj, "delta")
    delta = if is_map(delta), do: Payload.stringify_keys(delta), else: %{}

    case {index, Map.get(delta, "type")} do
      {idx, "text_delta"} when is_integer(idx) ->
        text = Map.get(delta, "text")

        if is_binary(text) and text != "" do
          emit.({:trace, {:ensure_item, "answer", :answer, nil}})
          emit.({:trace, {:append_text, "answer", :answer, idx + 1, text}})
        end

        append_content_block_text(state, idx, "text", text)

      {idx, "thinking_delta"} when is_integer(idx) ->
        thinking = Map.get(delta, "thinking")

        if is_binary(thinking) and thinking != "" do
          emit.({:trace, {:ensure_item, "reasoning", :reasoning, 1}})
          emit.({:trace, {:append_text, "reasoning", :reasoning, idx + 1, thinking}})
        end

        append_content_block_text(state, idx, "thinking", thinking)

      {idx, "signature_delta"} when is_integer(idx) ->
        put_content_block_value(state, idx, "signature", Map.get(delta, "signature"))

      {idx, "input_json_delta"} when is_integer(idx) ->
        partial = Map.get(delta, "partial_json")
        partial = if is_binary(partial), do: partial, else: ""

        state =
          state
          |> append_tool_input_json(idx, partial)
          |> put_content_block_value(
            idx,
            "input_json",
            current_tool_input_json(state, idx) <> partial
          )

        maybe_emit_tool_call(state, idx, emit)

      _other ->
        state
    end
  end

  defp handle_stream_event(
         state,
         %{"type" => "content_block_stop"} = obj,
         _raw_request,
         _url,
         emit
       ) do
    index = Map.get(obj, "index")

    if is_integer(index) do
      state = finalize_content_block(state, index)
      maybe_emit_tool_call(state, index, emit)
    else
      state
    end
  end

  defp handle_stream_event(state, %{"type" => "message_delta"} = obj, _raw_request, _url, _emit) do
    delta = Map.get(obj, "delta")
    delta = if is_map(delta), do: delta, else: %{}
    usage = normalize_usage(Map.get(obj, "usage"))

    state
    |> Map.put(:stop_reason, Map.get(delta, "stop_reason", state.stop_reason))
    |> Map.put(:usage, merge_usage(state.usage, usage))
    |> update_message(delta)
  end

  defp handle_stream_event(state, %{"type" => "message_stop"}, raw_request, _url, emit) do
    raw_response = build_raw_response(state)
    usage = normalized_trace_usage(raw_response)

    emit.({:trace, {:set_step_raw_request, raw_request}})
    emit.({:trace, {:set_step_raw_response, raw_response}})
    emit.({:trace, {:set_step_usage, usage}})
    emit.({:trace, {:set_step_response_final, true}})

    emit.(
      {:response_complete,
       %{
         provider: :anthropic_messages,
         raw_request: raw_request,
         raw_response: raw_response,
         usage: usage
       }}
    )

    %{state | done?: true}
  end

  defp handle_stream_event(state, %{"type" => "error"} = obj, raw_request, url, emit) do
    error = Map.get(obj, "error")
    error = if is_map(error), do: error, else: %{}

    emit.(
      {:response_error,
       %{
         provider: :anthropic_messages,
         status_code: nil,
         url: url,
         retryable: retryable_error_payload?(error),
         error_kind: "provider",
         error_text: error_message(error, "Provider error"),
         raw_request: raw_request,
         raw_response: obj
       }}
    )

    %{state | done?: true}
  end

  defp handle_stream_event(state, %{"type" => "ping"}, _raw_request, _url, _emit), do: state

  defp handle_stream_event(state, _obj, _raw_request, _url, _emit), do: state

  defp put_content_block(state, index, block) when is_integer(index) and is_map(block) do
    %{state | content_blocks: Map.put(state.content_blocks, index, block)}
  end

  defp append_content_block_text(state, index, key, text)
       when is_integer(index) and is_binary(key) do
    update_content_block(state, index, fn block ->
      current = block |> Map.get(key, "") |> to_string()
      Map.put(block, key, current <> to_string(text || ""))
    end)
  end

  defp put_content_block_value(state, index, key, value)
       when is_integer(index) and is_binary(key) do
    update_content_block(state, index, &Map.put(&1, key, value))
  end

  defp update_content_block(state, index, fun)
       when is_integer(index) and is_function(fun, 1) do
    block = Map.get(state.content_blocks, index, %{})
    %{state | content_blocks: Map.put(state.content_blocks, index, fun.(block))}
  end

  defp append_tool_input_json(state, index, partial) when is_integer(index) do
    current = current_tool_input_json(state, index)

    %{
      state
      | tool_input_json:
          Map.put(state.tool_input_json, index, current <> to_string(partial || ""))
    }
  end

  defp current_tool_input_json(state, index), do: Map.get(state.tool_input_json, index, "")

  defp finalize_content_block(state, index) when is_integer(index) do
    update_content_block(state, index, fn block ->
      case Map.get(block, "type") do
        "tool_use" ->
          input_json = current_tool_input_json(state, index)
          Map.put(block, "input", Payload.normalize_tool_input(input_json))

        _other ->
          block
      end
    end)
  end

  defp maybe_emit_tool_call(state, index, emit) when is_integer(index) and is_function(emit, 1) do
    block = Map.get(state.content_blocks, index)

    if is_map(block) and Map.get(block, "type") == "tool_use" do
      id = block |> Map.get("id") |> to_string() |> String.trim()
      name = block |> Map.get("name") |> to_string() |> String.trim()

      if id != "" and name != "" do
        input = tool_input_for_trace(block, state, index)
        arguments = encode_arguments(input)
        item_key = "tc:" <> id

        text =
          ["Tool call: #{name}", "Call ID: #{id}", "Arguments:", arguments]
          |> Enum.join("\n")
          |> String.trim()

        opaque = %{
          "tool_call_id" => id,
          "name" => name,
          "arguments" => input,
          "raw" =>
            block
            |> Map.put("input", input)
            |> Map.delete("input_json")
        }

        emit.({:trace, {:ensure_item, item_key, :tool_call, index + 1}})
        emit.({:trace, {:set_text, item_key, :tool_call, 1, text}})
        emit.({:trace, {:set_opaque, item_key, :tool_call, @opaque_sequence, opaque}})
      end
    end

    state
  end

  defp maybe_emit_tool_call(state, _index, _emit), do: state

  defp tool_input_for_trace(block, state, index) when is_map(block) do
    case Map.get(block, "input") do
      %{} = input ->
        Payload.stringify_keys(input)

      _other ->
        state
        |> current_tool_input_json(index)
        |> Payload.normalize_tool_input()
    end
  end

  defp encode_arguments(%{} = input), do: Jason.encode!(input)
  defp encode_arguments(input) when is_binary(input), do: input
  defp encode_arguments(input), do: to_string(input || "")

  defp update_message(state, delta) when is_map(delta) do
    message =
      Enum.reduce(delta, state.message, fn {key, value}, acc ->
        if is_nil(value), do: acc, else: Map.put(acc, key, value)
      end)

    %{state | message: message}
  end

  defp build_raw_response(state) do
    content =
      state.content_blocks
      |> Enum.sort_by(fn {index, _block} -> index end)
      |> Enum.map(fn {_index, block} ->
        block
        |> Map.delete("input_json")
        |> normalize_final_block()
      end)

    state.message
    |> Map.put_new("type", "message")
    |> Map.put_new("role", "assistant")
    |> Map.put("content", content)
    |> Map.put("stop_reason", state.stop_reason || Map.get(state.message, "stop_reason"))
    |> Map.put("usage", state.usage)
  end

  defp normalize_final_block(%{"type" => "tool_use"} = block) do
    Map.put(block, "input", Payload.normalize_tool_input(Map.get(block, "input")))
  end

  defp normalize_final_block(block), do: block

  defp normalize_usage(%{} = usage) do
    usage
    |> Payload.stringify_keys()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_usage(_usage), do: %{}

  defp merge_usage(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right)
  end

  defp normalized_trace_usage(%{"usage" => usage}) when is_map(usage) do
    input_tokens = coerce_int(Map.get(usage, "input_tokens"))
    output_tokens = coerce_int(Map.get(usage, "output_tokens"))

    cached_input_tokens =
      sum_present_ints([
        Map.get(usage, "cache_read_input_tokens"),
        Map.get(usage, "cache_creation_input_tokens")
      ])

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cached_input_tokens: cached_input_tokens,
      reasoning_tokens: nil,
      cost: nil
    }
  end

  defp normalized_trace_usage(_raw_response), do: nil

  defp sum_present_ints(values) do
    ints = values |> Enum.map(&coerce_int/1) |> Enum.reject(&is_nil/1)
    if ints == [], do: nil, else: Enum.sum(ints)
  end

  defp coerce_int(nil), do: nil
  defp coerce_int(value) when is_integer(value), do: value
  defp coerce_int(value) when is_float(value), do: trunc(value)

  defp coerce_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp coerce_int(_value), do: nil

  defp read_full_text(%Response{} = response) do
    response.body
    |> Enum.reduce([], fn chunk, acc -> [chunk | acc] end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp safe_json_decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  defp normalize_raw_response(value, fallback_text, status_code) do
    cond do
      is_map(value) ->
        maybe_put_status_code(value, status_code)

      is_nil(value) ->
        %{"raw_text" => String.trim(fallback_text || "")}
        |> maybe_put_status_code(status_code)

      true ->
        %{"raw" => value}
        |> maybe_put_status_code(status_code)
    end
  end

  defp maybe_put_status_code(raw_response, status_code)
       when is_map(raw_response) and is_integer(status_code) do
    Map.put_new(raw_response, "status_code", status_code)
  end

  defp maybe_put_status_code(raw_response, _status_code), do: raw_response

  defp extract_error_summary(%{"error" => error}, _fallback) when is_map(error) do
    error_message(error, inspect(error))
  end

  defp extract_error_summary(%{"error" => error}, _fallback) when is_binary(error),
    do: truncate(error)

  defp extract_error_summary(%{"message" => message}, _fallback) when is_binary(message) do
    truncate(message)
  end

  defp extract_error_summary(_json, fallback) when is_binary(fallback) do
    fallback
    |> String.trim()
    |> truncate()
  end

  defp error_message(error, fallback) when is_map(error) do
    message =
      error
      |> Map.get("message", Map.get(error, :message))
      |> to_string()
      |> String.trim()

    if message == "", do: truncate(fallback), else: truncate(message)
  end

  defp retryable_error_payload?(error) when is_map(error) do
    error_type =
      error
      |> Map.get("type", Map.get(error, :type))
      |> to_string()
      |> String.trim()

    MapSet.member?(@retryable_error_types, error_type)
  end

  defp retryable_error_payload?(_error), do: false

  defp truncate(value, limit \\ 500) when is_binary(value) and is_integer(limit) and limit > 0 do
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
