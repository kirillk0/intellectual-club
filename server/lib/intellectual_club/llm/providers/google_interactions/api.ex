defmodule IntellectualClub.Llm.Providers.GoogleInteractions.Api do
  @moduledoc """
  Google Interactions API streaming client.
  """

  alias IntellectualClub.Llm.Providers.GoogleInteractions.StreamEvents
  alias Req.Response

  @default_base_url "https://generativelanguage.googleapis.com/v1"
  @retryable_http_status_codes MapSet.new([429, 502, 503])

  @type trace_event :: IntellectualClub.Generation.RuntimeTrace.trace_event()

  @type event ::
          {:trace, trace_event()}
          | {:response_complete, map()}
          | {:response_error, map()}

  @spec stream_generate(
          %{
            optional(:base_url) => String.t() | nil,
            required(:api_key) => String.t(),
            required(:request_payload) => map(),
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

    url = String.trim_trailing(base_url, "/") <> "/interactions"
    payload = Map.get(opts, :request_payload, %{}) || %{}

    headers = [
      {"x-goog-api-key", api_key},
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
      into: :self,
      retry: false
    ]

    try do
      response = Req.request!(request_opts)

      cond do
        response.status >= 400 ->
          body_text = read_full_text(response)
          response_json = safe_json_decode(body_text)
          raw_response = normalize_raw_response(response_json, body_text, response.status)

          emit.(
            {:response_error,
             %{
               provider: :google_interactions,
               status_code: response.status,
               url: url,
               retryable: retryable_http_error?(response.status, response_json, body_text),
               error_kind: "http",
               error_text: extract_error_summary(response_json, body_text),
               raw_request: payload,
               raw_response: raw_response
             }}
          )

        stream_response?(response) ->
          stream_interactions(response, payload, url, emit)

        true ->
          response
          |> read_full_text()
          |> handle_full_response(payload, emit)
      end

      :ok
    rescue
      exception ->
        retryable = retryable_exception?(exception)

        emit.(
          {:response_error,
           %{
             provider: :google_interactions,
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
             provider: :google_interactions,
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

  defp default_base_url(nil), do: @default_base_url
  defp default_base_url(""), do: @default_base_url
  defp default_base_url(value), do: to_string(value)

  defp stream_response?(%Response{} = response) do
    response.headers
    |> Map.get("content-type", [])
    |> List.wrap()
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp stream_interactions(%Response{} = response, raw_request, url, emit) do
    state = StreamEvents.new_state()

    final_state =
      Enum.reduce_while(response.body, state, fn chunk, state ->
        state = feed_chunk(state, chunk, raw_request, emit)
        if state.done?, do: {:halt, state}, else: {:cont, state}
      end)

    if not final_state.done? do
      emit.(
        {:response_error,
         %{
           provider: :google_interactions,
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

  defp handle_sse_line(state, "event:" <> rest, _raw_request, _emit) do
    %{state | current_event: String.trim(rest)}
  end

  defp handle_sse_line(state, "data:" <> rest, _raw_request, _emit) do
    %{state | data_lines: state.data_lines ++ [String.trim(rest)]}
  end

  defp handle_sse_line(state, _line, _raw_request, _emit), do: state

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
          nil -> state
          obj -> StreamEvents.handle_event(state, obj, raw_request, emit)
        end
    end
  end

  defp handle_full_response(body_text, raw_request, emit) do
    case safe_json_decode(body_text) do
      %{} = response ->
        StreamEvents.emit_completed_response(response, raw_request, emit)

      _other ->
        emit.(
          {:response_error,
           %{
             provider: :google_interactions,
             status_code: nil,
             url: nil,
             retryable: false,
             error_kind: "provider",
             error_text: "Provider response is not valid JSON.",
             raw_request: raw_request,
             raw_response: normalize_raw_response(nil, body_text, nil)
           }}
        )
    end
  end

  defp safe_json_decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      _error -> nil
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

  defp read_full_text(%Response{} = response) do
    response.body
    |> Enum.reduce([], fn chunk, acc -> [acc | [chunk]] end)
    |> IO.iodata_to_binary()
  end

  defp extract_error_summary(%{"error" => %{"message" => message}}, _fallback)
       when is_binary(message) and message != "" do
    truncate_text(message, 500)
  end

  defp extract_error_summary(%{"error" => error}, _fallback) when is_binary(error) do
    truncate_text(error, 500)
  end

  defp extract_error_summary(%{"message" => message}, _fallback)
       when is_binary(message) and message != "" do
    truncate_text(message, 500)
  end

  defp extract_error_summary(_json, fallback) when is_binary(fallback) do
    fallback
    |> String.trim()
    |> truncate_text(500)
  end

  defp retryable_http_error?(status_code, response_json, body_text)
       when is_integer(status_code) do
    MapSet.member?(@retryable_http_status_codes, status_code) or
      (status_code == 500 and
         transient_error_text?(extract_error_summary(response_json, body_text)))
  end

  defp retryable_http_error?(_status_code, _response_json, _body_text), do: false

  defp transient_error_text?(text) when is_binary(text) do
    text = text |> String.trim() |> String.downcase()

    text != "" and
      (String.contains?(text, "high demand") or
         String.contains?(text, "try again later") or
         String.contains?(text, "temporarily unavailable") or
         String.contains?(text, "overloaded") or
         String.contains?(text, "rate limit") or
         String.contains?(text, "rate-limited"))
  end

  defp truncate_text(value, limit) when is_binary(value) and is_integer(limit) and limit > 0 do
    if String.length(value) <= limit do
      value
    else
      String.slice(value, 0, limit) <> "..."
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
