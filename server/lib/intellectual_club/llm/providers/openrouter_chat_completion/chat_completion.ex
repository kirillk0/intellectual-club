defmodule IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ChatCompletion do
  @moduledoc """
  OpenRouter Chat Completions (OpenAI-compatible) streaming client.

  This provider targets OpenRouter-specific behaviour:
  - Reasoning deltas may arrive under `reasoning` or `reasoning_content`
  - Some Anthropic backends reject non-conforming tool_call ids
  """

  alias Req.Response

  @retryable_http_status_codes MapSet.new([429, 502, 503])

  @non_append_string_keys ~w(format role name id type tool_call_id)
  @app_referer "https://github.com/kirillk0/intellectual-club"
  @app_title "Intellectual Club"

  @type event ::
          {:reasoning_delta, String.t(), map() | nil}
          | {:content_delta, String.t(), map() | nil}
          | {:tool_call_delta, map(), map() | nil}
          | {:raw_chunk, map()}
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

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    headers = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"},
      {"http-referer", @app_referer},
      {"x-openrouter-title", @app_title}
    ]

    request_opts = [
      url: url,
      method: :post,
      headers: headers,
      json: payload,
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
             provider: :openrouter_chat_completion,
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
        stream_chat_completions(response, payload, url, emit)
      end
    rescue
      exception ->
        retryable = retryable_exception?(exception)

        emit.(
          {:response_error,
           %{
             provider: :openrouter_chat_completion,
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
             provider: :openrouter_chat_completion,
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

  defp stream_chat_completions(%Response{} = response, raw_request, url, emit) do
    state = %{
      buffer: "",
      accumulator: new_accumulator(),
      finish_reason: nil,
      done?: false
    }

    final_state =
      Enum.reduce_while(response.body, state, fn chunk, state ->
        state = feed_chunk(state, chunk, emit)
        if state.done?, do: {:halt, state}, else: {:cont, state}
      end)

    raw_response = build_response(final_state.accumulator)
    usage = extract_usage(raw_response)

    finish_reason = final_state.finish_reason || "stop"

    cond do
      stream_error_response?(raw_response, finish_reason) ->
        {status_code, error_text, retryable} =
          classify_stream_error(raw_response, finish_reason: finish_reason)

        emit.(
          {:response_error,
           %{
             provider: :openrouter_chat_completion,
             status_code: status_code,
             url: url,
             retryable: retryable,
             error_kind: "provider",
             error_text: error_text,
             raw_request: raw_request,
             raw_response: raw_response
           }}
        )

      true ->
        emit.(
          {:response_complete,
           %{
             provider: :openrouter_chat_completion,
             finish_reason: finish_reason,
             raw_request: raw_request,
             raw_response: raw_response,
             usage: usage
           }}
        )
    end

    :ok
  end

  defp stream_error_response?(%{"error" => _error}, _finish_reason), do: true
  defp stream_error_response?(_raw_response, "error"), do: true
  defp stream_error_response?(_raw_response, _finish_reason), do: false

  defp classify_stream_error(raw_response, opts) when is_map(raw_response) and is_list(opts) do
    finish_reason = Keyword.get(opts, :finish_reason)
    error = Map.get(raw_response, "error")

    status_code =
      case error do
        %{} -> parse_int(Map.get(error, "code"))
        _ -> nil
      end

    retryable =
      is_integer(status_code) and MapSet.member?(@retryable_http_status_codes, status_code)

    error_text =
      case error do
        %{} ->
          error
          |> extract_error_message()
          |> case do
            "" -> truncate_text(inspect(error), 500)
            message -> truncate_text(message, 500)
          end

        _ ->
          "Provider stream finished with error#{if is_binary(finish_reason), do: ": #{finish_reason}", else: ""}"
      end

    {status_code, error_text, retryable}
  end

  defp classify_stream_error(_raw_response, opts) when is_list(opts) do
    finish_reason = Keyword.get(opts, :finish_reason)

    {nil,
     "Provider stream finished with error#{if is_binary(finish_reason), do: ": #{finish_reason}", else: ""}",
     false}
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_other), do: nil

  defp read_full_text(%Response{} = response) do
    response.body
    |> Enum.reduce([], fn chunk, acc -> [acc | [chunk]] end)
    |> IO.iodata_to_binary()
  end

  defp feed_chunk(state, chunk, emit) when is_binary(chunk) do
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
      handle_sse_line(state, String.trim(line), emit)
    end)
  end

  defp handle_sse_line(state, "", _emit), do: state

  defp handle_sse_line(state, ":" <> _comment, _emit), do: state

  defp handle_sse_line(state, line, emit) do
    data =
      if String.starts_with?(line, "data:") do
        line
        |> String.trim_leading("data:")
        |> String.trim()
      else
        String.trim(line)
      end

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
            state = update_accumulator(state, obj)
            emit_deltas(obj, emit, state)
        end
    end
  end

  defp update_accumulator(state, obj) when is_map(obj) do
    %{state | accumulator: accumulator_add(state.accumulator, obj)}
  end

  defp emit_deltas(obj, emit, state) do
    choices = Map.get(obj, "choices") || []
    first_choice = if is_list(choices), do: List.first(choices), else: nil
    first_choice = if is_map(first_choice), do: first_choice, else: %{}
    choice_index = Map.get(first_choice, "index", 0)
    choice_index = if is_integer(choice_index) and choice_index >= 0, do: choice_index, else: 0

    delta =
      case Map.get(first_choice, "delta") do
        value when is_map(value) -> value
        _ -> %{}
      end

    message =
      case Map.get(first_choice, "message") do
        value when is_map(value) -> value
        _ -> %{}
      end

    {content_piece, reasoning_piece} =
      cond do
        delta != %{} ->
          {Map.get(delta, "content"), extract_reasoning(delta)}

        message != %{} ->
          {Map.get(message, "content"), extract_reasoning(message)}

        true ->
          {nil, nil}
      end

    tool_calls_source =
      cond do
        delta != %{} ->
          Map.get(delta, "tool_calls")

        message != %{} ->
          Map.get(message, "tool_calls")

        true ->
          nil
      end

    finish_reason = Map.get(first_choice, "finish_reason")

    state =
      if is_binary(finish_reason) and finish_reason != "" do
        %{state | finish_reason: finish_reason}
      else
        state
      end

    reasoning_piece =
      cond do
        is_binary(reasoning_piece) -> reasoning_piece
        is_nil(reasoning_piece) -> nil
        true -> to_string(reasoning_piece)
      end

    content_piece =
      cond do
        is_binary(content_piece) -> content_piece
        is_nil(content_piece) -> nil
        true -> to_string(content_piece)
      end

    has_reasoning = is_binary(reasoning_piece) and reasoning_piece != ""
    has_content = is_binary(content_piece) and content_piece != ""

    if has_reasoning do
      emit.({:reasoning_delta, reasoning_piece, obj})
    end

    if has_content do
      emit.({:content_delta, content_piece, obj})
    end

    emit_tool_call_deltas(tool_calls_source, choice_index, state, obj, emit)

    if not has_reasoning and not has_content and not is_nil(finish_reason) do
      emit.({:raw_chunk, obj})
    end

    state
  end

  defp safe_json_decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp emit_tool_call_deltas(tool_calls_source, choice_index, state, raw_chunk, emit)
       when is_list(tool_calls_source) and is_integer(choice_index) and choice_index >= 0 and
              is_function(emit, 1) do
    merged_tool_calls =
      state.accumulator
      |> Map.get(:choices, %{})
      |> Map.get(choice_index, %{})
      |> Map.get("tool_calls")
      |> case do
        list when is_list(list) -> list
        _other -> []
      end

    tool_calls_source
    |> Enum.with_index()
    |> Enum.each(fn {tool_call_delta, fallback_index} ->
      if is_map(tool_call_delta) do
        tool_call_index =
          case Map.get(tool_call_delta, "index") do
            value when is_integer(value) and value >= 0 -> value
            _other -> fallback_index
          end

        merged_tool_call =
          case Enum.at(merged_tool_calls, tool_call_index) do
            %{} = call -> call
            _other -> tool_call_delta
          end

        case normalize_stream_tool_call(merged_tool_call, tool_call_index) do
          %{} = tool_call ->
            emit.({:tool_call_delta, tool_call, raw_chunk})

          _other ->
            :ok
        end
      end
    end)
  end

  defp emit_tool_call_deltas(_tool_calls_source, _choice_index, _state, _raw_chunk, _emit),
    do: :ok

  defp normalize_stream_tool_call(tool_call, index)
       when is_map(tool_call) and is_integer(index) and index >= 0 do
    call_id =
      tool_call
      |> Map.get("id")
      |> to_string()
      |> String.trim()

    function = Map.get(tool_call, "function")
    function = if is_map(function), do: function, else: %{}

    name =
      function
      |> Map.get("name")
      |> to_string()
      |> String.trim()

    arguments =
      case Map.get(function, "arguments") do
        value when is_binary(value) -> value
        %{} = value -> Jason.encode!(value)
        value when is_nil(value) -> ""
        value -> to_string(value)
      end

    if call_id != "" and name != "" do
      %{
        call_id: call_id,
        name: name,
        arguments: arguments,
        index: index,
        raw: Map.new(tool_call)
      }
    else
      nil
    end
  end

  defp normalize_stream_tool_call(_tool_call, _index), do: nil

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

  defp extract_error_summary(%{"error" => error} = _json, _fallback) when is_map(error) do
    error
    |> extract_error_message()
    |> case do
      "" -> truncate_text(inspect(error), 500)
      message -> truncate_text(message, 500)
    end
  end

  defp extract_error_summary(%{"error" => error} = _json, _fallback) when is_binary(error) do
    truncate_text(error, 500)
  end

  defp extract_error_summary(%{"message" => message} = _json, _fallback)
       when is_binary(message) and message != "" do
    truncate_text(message, 500)
  end

  defp extract_error_summary(_json, fallback) when is_binary(fallback) do
    fallback
    |> String.trim()
    |> truncate_text(500)
  end

  defp extract_error_message(error) when is_map(error) do
    message = trimmed_string(Map.get(error, "message") || Map.get(error, :message))
    raw = raw_error_message(error)

    cond do
      raw != "" and generic_error_message?(message) ->
        raw

      message != "" ->
        message

      raw != "" ->
        raw

      true ->
        ""
    end
  end

  defp raw_error_message(error) when is_map(error) do
    metadata = Map.get(error, "metadata") || Map.get(error, :metadata)

    case metadata do
      %{} ->
        trimmed_string(Map.get(metadata, "raw") || Map.get(metadata, :raw))

      _other ->
        ""
    end
  end

  defp generic_error_message?(message) when is_binary(message) do
    message
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["", "error", "provider error", "provider returned error"]))
  end

  defp generic_error_message?(_message), do: true

  defp trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp trimmed_string(nil), do: ""
  defp trimmed_string(value), do: value |> to_string() |> String.trim()

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

  defp extract_usage(%{"usage" => usage} = raw_response)
       when is_map(usage) and is_map(raw_response) do
    input_tokens =
      coerce_int(Map.get(usage, "prompt_tokens")) || coerce_int(Map.get(usage, "input_tokens"))

    output_tokens =
      coerce_int(Map.get(usage, "completion_tokens")) ||
        coerce_int(Map.get(usage, "output_tokens"))

    cached_input_tokens =
      usage
      |> Map.get("input_tokens_details")
      |> nested_int("cached_tokens") ||
        usage
        |> Map.get("prompt_tokens_details")
        |> nested_int("cached_tokens")

    reasoning_tokens =
      usage
      |> Map.get("output_tokens_details")
      |> nested_int("reasoning_tokens") ||
        usage
        |> Map.get("completion_tokens_details")
        |> nested_int("reasoning_tokens")

    cost =
      coerce_float(Map.get(usage, "cost")) ||
        coerce_float(Map.get(usage, "total_cost")) ||
        coerce_float(Map.get(usage, "total_cost_usd")) ||
        coerce_float(Map.get(raw_response, "cost"))

    if is_nil(input_tokens) and is_nil(output_tokens) and is_nil(cached_input_tokens) and
         is_nil(reasoning_tokens) and is_nil(cost) do
      nil
    else
      %{
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cached_input_tokens: cached_input_tokens,
        reasoning_tokens: reasoning_tokens,
        cost: cost
      }
    end
  end

  defp extract_usage(_raw_response), do: nil

  defp coerce_int(nil), do: nil
  defp coerce_int(value) when is_boolean(value), do: nil
  defp coerce_int(value) when is_integer(value), do: value
  defp coerce_int(value) when is_float(value), do: trunc(value)

  defp coerce_int(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      case Float.parse(value) do
        {number, _rest} -> trunc(number)
        :error -> nil
      end
    end
  end

  defp coerce_int(_value), do: nil

  defp coerce_float(nil), do: nil
  defp coerce_float(value) when is_boolean(value), do: nil
  defp coerce_float(value) when is_integer(value), do: value / 1
  defp coerce_float(value) when is_float(value), do: value

  defp coerce_float(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      case Float.parse(value) do
        {number, _rest} -> number
        :error -> nil
      end
    end
  end

  defp coerce_float(_value), do: nil

  defp nested_int(value, key) when is_map(value), do: coerce_int(Map.get(value, key))
  defp nested_int(_value, _key), do: nil

  defp extract_reasoning(delta) when is_map(delta) do
    cond do
      Map.has_key?(delta, "reasoning_content") ->
        delta
        |> Map.get("reasoning_content")
        |> flatten_reasoning()

      Map.has_key?(delta, "reasoning") ->
        delta
        |> Map.get("reasoning")
        |> flatten_reasoning()

      true ->
        nil
    end
  end

  defp extract_reasoning(_delta), do: nil

  defp flatten_reasoning(nil), do: nil

  defp flatten_reasoning(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp flatten_reasoning(value) when is_map(value) do
    nested = Map.get(value, "text") || Map.get(value, "content")

    text =
      cond do
        is_list(nested) ->
          Enum.map_join(nested, "", &to_string/1)

        not is_nil(nested) ->
          to_string(nested)

        true ->
          value
          |> Map.values()
          |> Enum.filter(fn v -> is_binary(v) or is_integer(v) or is_float(v) end)
          |> Enum.map_join(" ", &to_string/1)
      end

    if text == "", do: nil, else: text
  end

  defp flatten_reasoning(value) when is_list(value) do
    text =
      Enum.map_join(value, "", fn item ->
        cond do
          is_map(item) -> to_string(Map.get(item, "text") || Map.get(item, "content") || "")
          true -> to_string(item)
        end
      end)

    if text == "", do: nil, else: text
  end

  defp flatten_reasoning(value) do
    text = to_string(value)
    if text == "", do: nil, else: text
  end

  defp new_accumulator do
    %{
      full_response: nil,
      error_chunk: nil,
      id: nil,
      created: nil,
      model: nil,
      system_fingerprint: nil,
      provider: nil,
      usage: nil,
      choices: %{},
      finish_reasons: %{},
      logprobs: %{}
    }
  end

  defp accumulator_add(acc, obj) when is_map(obj) do
    if acc.full_response != nil do
      acc
    else
      acc
      |> maybe_capture_meta(obj)
      |> maybe_capture_full_response(obj)
      |> maybe_capture_choices(obj)
    end
  end

  defp maybe_capture_meta(acc, obj) do
    acc =
      if acc.error_chunk == nil and Map.has_key?(obj, "error") do
        %{acc | error_chunk: obj}
      else
        acc
      end

    acc =
      if acc.id == nil do
        %{acc | id: Map.get(obj, "id")}
      else
        acc
      end

    acc =
      if acc.created == nil do
        %{acc | created: Map.get(obj, "created")}
      else
        acc
      end

    acc =
      if acc.model == nil do
        %{acc | model: Map.get(obj, "model")}
      else
        acc
      end

    acc =
      if acc.system_fingerprint == nil do
        %{acc | system_fingerprint: Map.get(obj, "system_fingerprint")}
      else
        acc
      end

    acc =
      if acc.provider == nil do
        %{acc | provider: Map.get(obj, "provider")}
      else
        acc
      end

    if Map.has_key?(obj, "usage") do
      %{acc | usage: Map.get(obj, "usage")}
    else
      acc
    end
  end

  defp maybe_capture_full_response(acc, %{"choices" => [%{"message" => _} | _]} = obj) do
    if has_delta?(obj) do
      acc
    else
      %{acc | full_response: obj}
    end
  end

  defp maybe_capture_full_response(acc, _obj), do: acc

  defp has_delta?(%{"choices" => choices}) when is_list(choices) do
    Enum.any?(choices, fn choice -> is_map(choice) and Map.has_key?(choice, "delta") end)
  end

  defp has_delta?(_), do: false

  defp maybe_capture_choices(acc, %{"choices" => choices}) when is_list(choices) do
    Enum.reduce(choices, acc, fn choice, acc ->
      if is_map(choice) do
        index = Map.get(choice, "index", 0)

        if is_integer(index) and index >= 0 do
          message = Map.get(acc.choices, index, %{"role" => nil, "content" => ""})
          delta = Map.get(choice, "delta") || %{}
          message = if is_map(delta), do: merge_dict(message, delta), else: message

          acc =
            put_in(acc.choices[index], message)
            |> maybe_put_finish_reason(index, choice)
            |> maybe_put_logprobs(index, choice)

          acc
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp maybe_capture_choices(acc, _obj), do: acc

  defp maybe_put_finish_reason(acc, index, choice) do
    finish_reason = Map.get(choice, "finish_reason")

    if is_nil(finish_reason) do
      acc
    else
      put_in(acc.finish_reasons[index], finish_reason)
    end
  end

  defp maybe_put_logprobs(acc, index, choice) do
    if Map.has_key?(choice, "logprobs") do
      put_in(acc.logprobs[index], Map.get(choice, "logprobs"))
    else
      acc
    end
  end

  defp build_response(acc) do
    cond do
      is_map(acc.full_response) ->
        acc.full_response

      is_map(acc.error_chunk) ->
        acc.error_chunk

      map_size(acc.choices) == 0 ->
        nil

      true ->
        choices_out =
          acc.choices
          |> Map.keys()
          |> Enum.sort()
          |> Enum.map(fn index ->
            message =
              acc.choices[index]
              |> Map.new()
              |> Map.update("role", "assistant", fn
                nil -> "assistant"
                other -> other
              end)
              |> Map.update("content", "", fn
                nil -> ""
                other -> other
              end)
              |> maybe_drop_empty_tool_calls()

            out = %{
              "index" => index,
              "message" => message,
              "finish_reason" => Map.get(acc.finish_reasons, index)
            }

            if Map.has_key?(acc.logprobs, index) do
              Map.put(out, "logprobs", Map.get(acc.logprobs, index))
            else
              out
            end
          end)

        base = %{
          "id" => acc.id,
          "object" => "chat.completion",
          "created" => acc.created,
          "model" => acc.model,
          "choices" => choices_out
        }

        base
        |> maybe_put_if_present("system_fingerprint", acc.system_fingerprint)
        |> maybe_put_if_present("provider", acc.provider)
        |> maybe_put_if_present("usage", acc.usage)
    end
  end

  defp maybe_drop_empty_tool_calls(message) do
    tool_calls = Map.get(message, "tool_calls")

    if tool_calls == [] do
      Map.delete(message, "tool_calls")
    else
      message
    end
  end

  defp maybe_put_if_present(map, _key, nil), do: map
  defp maybe_put_if_present(map, key, value), do: Map.put(map, key, value)

  defp merge_dict(target, incoming) when is_map(target) and is_map(incoming) do
    Enum.reduce(incoming, target, fn {key, value}, target ->
      if key == "tool_calls" do
        merge_tool_calls(target, value)
      else
        merge_value(target, key, value)
      end
    end)
  end

  defp merge_value(target, _key, nil), do: target

  defp merge_value(target, key, value) when is_map(value) do
    existing = Map.get(target, key)
    existing = if is_map(existing), do: existing, else: %{}
    Map.put(target, key, merge_dict(existing, value))
  end

  defp merge_value(target, key, value) when is_list(value) do
    existing = Map.get(target, key)

    cond do
      not is_list(existing) ->
        Map.put(target, key, deep_copy_list(value))

      true ->
        Map.put(target, key, merge_list(existing, value))
    end
  end

  defp merge_value(target, key, value) when is_binary(value) do
    existing = Map.get(target, key)

    cond do
      is_binary(existing) and key not in @non_append_string_keys ->
        Map.put(target, key, existing <> value)

      existing in [nil, ""] or not Map.has_key?(target, key) ->
        Map.put(target, key, value)

      true ->
        target
    end
  end

  defp merge_value(target, key, value) do
    Map.put(target, key, value)
  end

  defp deep_copy_list(list) do
    Enum.map(list, fn
      value when is_map(value) -> Map.new(value)
      value when is_list(value) -> deep_copy_list(value)
      value -> value
    end)
  end

  defp merge_list(target, incoming) when is_list(target) and is_list(incoming) do
    has_index =
      Enum.any?(incoming, fn
        %{"index" => _} -> true
        _ -> false
      end)

    if not has_index do
      target ++ deep_copy_list(incoming)
    else
      Enum.reduce(incoming, target, fn item, target ->
        if is_map(item) and is_integer(Map.get(item, "index")) and Map.get(item, "index") >= 0 do
          index = Map.get(item, "index")
          payload = Map.delete(item, "index")
          target = pad_list_with_maps(target, index)
          current = Enum.at(target, index) || %{}
          current = if is_map(current), do: current, else: %{}
          updated = merge_dict(current, payload)
          List.replace_at(target, index, updated)
        else
          target ++ deep_copy_list([item])
        end
      end)
    end
  end

  defp pad_list_with_maps(list, index) do
    if length(list) > index do
      list
    else
      missing = index - length(list) + 1
      list ++ List.duplicate(%{}, missing)
    end
  end

  defp merge_tool_calls(message, tool_calls) when is_map(message) do
    if not is_list(tool_calls) do
      message
    else
      merged = Map.get(message, "tool_calls")
      merged = if is_list(merged), do: merged, else: []

      merged =
        Enum.reduce(tool_calls, merged, fn tool_call, merged ->
          if is_map(tool_call) do
            index = Map.get(tool_call, "index")
            payload = Map.delete(tool_call, "index")

            if is_integer(index) and index >= 0 do
              merged = pad_list_with_maps(merged, index)
              current = Enum.at(merged, index) || %{}
              current = if is_map(current), do: current, else: %{}
              updated = merge_dict(current, payload)
              List.replace_at(merged, index, updated)
            else
              merged ++ [payload]
            end
          else
            merged
          end
        end)

      Map.put(message, "tool_calls", merged)
    end
  end
end
