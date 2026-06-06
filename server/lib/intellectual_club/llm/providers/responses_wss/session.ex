defmodule IntellectualClub.Llm.Providers.ResponsesWss.Session do
  @moduledoc """
  Turn-scoped Responses API WebSocket session.
  """

  use GenServer

  alias IntellectualClub.Llm.Providers.Responses.StreamEvents

  @default_base_url "https://api.openai.com/v1"
  @openai_beta_header "responses_websockets=2026-02-06"
  @retryable_http_status_codes MapSet.new([429, 502, 503])

  @type trace_event :: IntellectualClub.Generation.RuntimeTrace.trace_event()

  @type event ::
          {:trace, trace_event()}
          | {:response_complete, map()}
          | {:response_error, map()}

  @type state :: %{
          context: map(),
          connection: map() | nil,
          last_request: map() | nil,
          last_response: map() | nil
        }

  @spec start(map()) :: GenServer.on_start()
  def start(context) when is_map(context) do
    GenServer.start(__MODULE__, context)
  end

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(context) when is_map(context) do
    GenServer.start_link(__MODULE__, context)
  end

  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end

    :ok
  end

  @spec stream_generate(pid(), map(), (event() -> any())) :: :ok
  def stream_generate(pid, opts, emit)
      when is_pid(pid) and is_map(opts) and is_function(emit, 1) do
    GenServer.call(pid, {:stream_generate, opts, emit}, :infinity)
  end

  @impl true
  def init(context) when is_map(context) do
    {:ok,
     %{
       context: context,
       connection: nil,
       last_request: nil,
       last_response: nil
     }}
  end

  @impl true
  def handle_call({:stream_generate, opts, emit}, _from, state) do
    provider =
      Map.get(opts, :provider) || Map.get(state.context, :provider_type) || :responses_wss

    logical_request = stringify_keys(Map.get(opts, :request_payload, %{}) || %{})
    timeout_ms = Map.get(opts, :timeout_ms, 300_000)

    with {:ok, url} <-
           websocket_url(Map.get(opts, :base_url) || Map.get(state.context, :provider_base_url)),
         {:ok, connection, state} <- ensure_connection(state, opts, url),
         {:ok, wire_payload} <- wire_payload(logical_request, state),
         {:ok, connection} <- send_payload(connection, wire_payload) do
      state = %{state | connection: connection}

      case receive_response(connection, logical_request, provider, timeout_ms, emit) do
        {:ok, connection, response} ->
          {:reply, :ok, remember_completed_response(state, connection, logical_request, response)}

        {:error, connection, error_meta} ->
          state = reset_transport_state(%{state | connection: connection})
          maybe_emit_response_error(emit, provider, logical_request, error_meta)
          {:reply, :ok, state}
      end
    else
      {:error, error_meta} when is_map(error_meta) ->
        state = reset_transport_state(state)
        maybe_emit_response_error(emit, provider, logical_request, error_meta)
        {:reply, :ok, state}

      {:error, connection, error_meta} when is_map(error_meta) ->
        state = reset_transport_state(%{state | connection: connection})
        maybe_emit_response_error(emit, provider, logical_request, error_meta)
        {:reply, :ok, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_connection(Map.get(state, :connection))
    :ok
  end

  @doc false
  @spec websocket_url(String.t() | nil) :: {:ok, map()} | {:error, map()}
  def websocket_url(base_url) do
    base_url
    |> default_base_url()
    |> URI.parse()
    |> normalize_websocket_uri()
  end

  @doc false
  @spec wire_payload(map(), state()) :: {:ok, map()}
  def wire_payload(logical_request, state) when is_map(logical_request) and is_map(state) do
    full_payload =
      logical_request
      |> stringify_keys()
      |> Map.drop(["stream", "background"])
      |> Map.put("type", "response.create")

    {:ok, maybe_put_continuation(full_payload, state)}
  end

  defp default_base_url(nil), do: @default_base_url
  defp default_base_url(""), do: @default_base_url
  defp default_base_url(value), do: to_string(value)

  defp normalize_websocket_uri(%URI{scheme: scheme, host: host} = uri)
       when scheme in ["http", "https", "ws", "wss"] and is_binary(host) do
    websocket_scheme =
      case scheme do
        "http" -> "ws"
        "https" -> "wss"
        other -> other
      end

    path =
      uri.path
      |> normalize_uri_path()
      |> append_responses_path()

    uri = %{uri | scheme: websocket_scheme, path: path}
    port = uri.port || default_port(websocket_scheme)

    {:ok,
     %{
       uri: uri,
       scheme: websocket_scheme,
       connect_scheme: connect_scheme(websocket_scheme),
       upgrade_scheme: upgrade_scheme(websocket_scheme),
       host: host,
       port: port,
       path: path_with_query(uri)
     }}
  end

  defp normalize_websocket_uri(_uri) do
    {:error,
     %{
       status_code: nil,
       url: nil,
       retryable: false,
       error_kind: "transport",
       error_text: "Invalid Responses WSS base URL",
       raw_response: nil
     }}
  end

  defp normalize_uri_path(nil), do: "/"
  defp normalize_uri_path(""), do: "/"
  defp normalize_uri_path(path), do: path

  defp append_responses_path(path) when is_binary(path) do
    path = String.trim_trailing(path, "/")

    cond do
      path == "" -> "/responses"
      String.ends_with?(path, "/responses") -> path
      true -> path <> "/responses"
    end
  end

  defp default_port("ws"), do: 80
  defp default_port("wss"), do: 443

  defp connect_scheme("ws"), do: :http
  defp connect_scheme("wss"), do: :https

  defp upgrade_scheme("ws"), do: :ws
  defp upgrade_scheme("wss"), do: :wss

  defp path_with_query(%URI{path: path, query: nil}), do: path
  defp path_with_query(%URI{path: path, query: ""}), do: path
  defp path_with_query(%URI{path: path, query: query}), do: path <> "?" <> query

  defp ensure_connection(%{connection: %{url: url} = connection} = state, _opts, url) do
    {:ok, connection, state}
  end

  defp ensure_connection(state, opts, url) do
    state = reset_transport_state(state)

    case connect(url, Map.fetch!(opts, :api_key), Map.get(opts, :connect_timeout_ms, 10_000)) do
      {:ok, connection} ->
        {:ok, connection, %{state | connection: connection}}

      {:error, error_meta} ->
        {:error, error_meta}
    end
  end

  defp connect(url, api_key, connect_timeout_ms) do
    opts = [
      mode: :passive,
      protocols: [:http1],
      transport_opts: [timeout: connect_timeout_ms]
    ]

    with {:ok, conn} <- Mint.HTTP.connect(url.connect_scheme, url.host, url.port, opts),
         {:ok, conn, ref} <- upgrade_connection(conn, url, api_key),
         {:ok, conn, status, headers} <- receive_upgrade(conn, ref, connect_timeout_ms),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers, mode: :passive) do
      {:ok, %{conn: conn, websocket: websocket, ref: ref, url: url}}
    else
      {:error, conn, error} ->
        close_mint_connection(conn)
        {:error, connection_error_meta(error, url)}

      {:error, conn, error, _responses} ->
        close_mint_connection(conn)
        {:error, connection_error_meta(error, url)}

      {:error, error} ->
        {:error, connection_error_meta(error, url)}
    end
  end

  defp upgrade_connection(conn, url, api_key) do
    headers = [
      {"authorization", "Bearer " <> api_key},
      {"openai-beta", @openai_beta_header}
    ]

    Mint.WebSocket.upgrade(url.upgrade_scheme, conn, url.path, headers,
      extensions: [Mint.WebSocket.PerMessageDeflate]
    )
  end

  defp receive_upgrade(conn, ref, timeout_ms) do
    receive_upgrade(conn, ref, timeout_ms, nil, [])
  end

  defp receive_upgrade(conn, ref, timeout_ms, status, headers) do
    case Mint.HTTP.recv(conn, 0, timeout_ms) do
      {:ok, conn, responses} ->
        {status, headers, done?} = reduce_upgrade_responses(responses, ref, status, headers)

        if done? do
          {:ok, conn, status || 0, headers}
        else
          receive_upgrade(conn, ref, timeout_ms, status, headers)
        end

      {:error, conn, error, responses} ->
        {status, headers, done?} = reduce_upgrade_responses(responses, ref, status, headers)

        if done? do
          {:ok, conn, status || 0, headers}
        else
          {:error, conn, error, responses}
        end
    end
  end

  defp reduce_upgrade_responses(responses, ref, status, headers) do
    Enum.reduce(responses, {status, headers, false}, fn
      {:status, ^ref, next_status}, {_status, headers, done?} ->
        {next_status, headers, done?}

      {:headers, ^ref, next_headers}, {status, _headers, done?} ->
        {status, next_headers, done?}

      {:done, ^ref}, {status, headers, _done?} ->
        {status, headers, true}

      _other, acc ->
        acc
    end)
  end

  defp send_payload(%{conn: conn, websocket: websocket, ref: ref} = connection, wire_payload) do
    case Jason.encode(wire_payload) do
      {:ok, json} ->
        case Mint.WebSocket.encode(websocket, {:text, json}) do
          {:ok, websocket, data} ->
            case Mint.WebSocket.stream_request_body(conn, ref, data) do
              {:ok, conn} ->
                {:ok, %{connection | conn: conn, websocket: websocket}}

              {:error, conn, error} ->
                {:error, %{connection | conn: conn, websocket: websocket},
                 send_error_meta(error, Map.get(connection, :url))}
            end

          {:error, websocket, error} ->
            {:error, %{connection | websocket: websocket},
             send_error_meta(error, Map.get(connection, :url))}
        end

      {:error, error} ->
        {:error, connection, send_error_meta(error, Map.get(connection, :url))}
    end
  end

  defp receive_response(connection, logical_request, provider, timeout_ms, emit) do
    stream_state = StreamEvents.new_state()
    key = {__MODULE__, make_ref()}
    Process.delete(key)

    wrapped_emit = capture_terminal_event(emit, provider, key)

    result = receive_frames(connection, stream_state, logical_request, timeout_ms, wrapped_emit)

    terminal = Process.get(key)
    Process.delete(key)

    case result do
      {:ok, connection, _state} ->
        case terminal do
          {:response_complete, meta} ->
            {:ok, connection,
             Map.get(meta, :raw_response) || Map.get(meta, "raw_response") || %{}}

          {:response_error, meta} ->
            meta =
              meta
              |> Map.put_new(:retryable, retryable_terminal_error?(meta))
              |> Map.put(:already_emitted, true)

            {:error, connection, meta}

          _other ->
            {:error, connection,
             %{
               status_code: nil,
               url: url_string(Map.get(connection, :url)),
               retryable: true,
               error_kind: "network",
               error_text: "WebSocket stream ended without a terminal event",
               raw_response: nil
             }}
        end

      {:error, connection, error_meta} ->
        {:error, connection, error_meta}
    end
  end

  defp capture_terminal_event(emit, provider, key) do
    fn
      {:response_complete, meta} ->
        meta = rewrite_provider(meta, provider)
        Process.put(key, {:response_complete, meta})
        emit.({:response_complete, meta})

      {:response_error, meta} ->
        meta = rewrite_provider(meta, provider)
        Process.put(key, {:response_error, meta})
        emit.({:response_error, meta})

      {:trace, _trace_event} = event ->
        emit.(event)
    end
  end

  defp rewrite_provider(meta, provider) when is_map(meta) do
    Map.put(meta, :provider, provider)
  end

  defp receive_frames(
         %{conn: conn, websocket: websocket} = connection,
         stream_state,
         logical_request,
         timeout_ms,
         emit
       ) do
    case Mint.WebSocket.recv(conn, 0, timeout_ms) do
      {:ok, conn, responses} ->
        connection = %{connection | conn: conn}

        case decode_responses(connection, responses, stream_state, logical_request, emit) do
          {:ok, connection, stream_state} ->
            if stream_state.done? do
              {:ok, connection, stream_state}
            else
              receive_frames(connection, stream_state, logical_request, timeout_ms, emit)
            end

          {:error, connection, error_meta} ->
            {:error, connection, error_meta}
        end

      {:error, conn, reason, _responses} ->
        connection = %{connection | conn: conn, websocket: websocket}
        {:error, connection, receive_error_meta(reason, Map.get(connection, :url))}
    end
  end

  defp decode_responses(connection, responses, stream_state, logical_request, emit) do
    Enum.reduce_while(responses, {:ok, connection, stream_state}, fn
      {:data, ref, data}, {:ok, %{ref: ref} = connection, stream_state} ->
        case Mint.WebSocket.decode(connection.websocket, data) do
          {:ok, websocket, frames} ->
            connection = %{connection | websocket: websocket}

            case handle_frames(connection, frames, stream_state, logical_request, emit) do
              {:ok, connection, stream_state} -> {:cont, {:ok, connection, stream_state}}
              {:error, connection, error_meta} -> {:halt, {:error, connection, error_meta}}
            end

          {:error, websocket, error} ->
            connection = %{connection | websocket: websocket}
            {:halt, {:error, connection, frame_error_meta(error, Map.get(connection, :url))}}
        end

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp handle_frames(connection, frames, stream_state, logical_request, emit) do
    Enum.reduce_while(frames, {:ok, connection, stream_state}, fn frame,
                                                                  {:ok, connection, stream_state} ->
      case handle_frame(connection, frame, stream_state, logical_request, emit) do
        {:ok, connection, stream_state} -> {:cont, {:ok, connection, stream_state}}
        {:error, connection, error_meta} -> {:halt, {:error, connection, error_meta}}
      end
    end)
  end

  defp handle_frame(connection, {:text, text}, stream_state, logical_request, emit) do
    case Jason.decode(text) do
      {:ok, %{} = event} ->
        stream_state = StreamEvents.handle_event(stream_state, event, logical_request, emit)
        {:ok, connection, stream_state}

      {:ok, _other} ->
        {:ok, connection, stream_state}

      {:error, error} ->
        {:error, connection, frame_error_meta(error, Map.get(connection, :url))}
    end
  end

  defp handle_frame(connection, {:ping, payload}, stream_state, _logical_request, _emit) do
    case send_control_frame(connection, {:pong, payload}) do
      {:ok, connection} -> {:ok, connection, stream_state}
      {:error, connection, error_meta} -> {:error, connection, error_meta}
    end
  end

  defp handle_frame(connection, {:pong, _payload}, stream_state, _logical_request, _emit) do
    {:ok, connection, stream_state}
  end

  defp handle_frame(connection, {:close, code, reason}, _stream_state, _logical_request, _emit) do
    {:error, connection,
     %{
       status_code: nil,
       url: url_string(Map.get(connection, :url)),
       retryable: true,
       error_kind: "network",
       error_text: "WebSocket closed before response.completed: #{inspect({code, reason})}",
       raw_response: nil
     }}
  end

  defp handle_frame(connection, {:binary, _data}, _stream_state, _logical_request, _emit) do
    {:error, connection,
     %{
       status_code: nil,
       url: url_string(Map.get(connection, :url)),
       retryable: true,
       error_kind: "transport",
       error_text: "Unexpected binary WebSocket frame",
       raw_response: nil
     }}
  end

  defp handle_frame(connection, {:error, error}, _stream_state, _logical_request, _emit) do
    {:error, connection, frame_error_meta(error, Map.get(connection, :url))}
  end

  defp send_control_frame(%{conn: conn, websocket: websocket, ref: ref} = connection, frame) do
    case Mint.WebSocket.encode(websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn} ->
            {:ok, %{connection | conn: conn, websocket: websocket}}

          {:error, conn, error} ->
            {:error, %{connection | conn: conn, websocket: websocket},
             send_error_meta(error, Map.get(connection, :url))}
        end

      {:error, websocket, error} ->
        {:error, %{connection | websocket: websocket},
         send_error_meta(error, Map.get(connection, :url))}
    end
  end

  defp maybe_put_continuation(full_payload, %{
         last_request: %{} = last_request,
         last_response: %{} = last_response
       }) do
    last_request_payload =
      last_request
      |> stringify_keys()
      |> Map.drop(["stream", "background"])
      |> Map.put("type", "response.create")

    response_id = Map.get(last_response, "id")
    previous_input = Map.get(last_request_payload, "input") || []
    previous_output = Map.get(last_response, "output") || []
    current_input = Map.get(full_payload, "input") || []
    prefix = previous_input ++ previous_output

    if is_binary(response_id) and response_id != "" and
         comparable_payloads?(last_request_payload, full_payload) and
         list_prefix?(current_input, prefix) do
      full_payload
      |> Map.put("previous_response_id", response_id)
      |> Map.put("input", Enum.drop(current_input, length(prefix)))
    else
      Map.delete(full_payload, "previous_response_id")
    end
  end

  defp maybe_put_continuation(full_payload, _state) do
    Map.delete(full_payload, "previous_response_id")
  end

  defp comparable_payloads?(previous_payload, current_payload)
       when is_map(previous_payload) and is_map(current_payload) do
    Map.delete(previous_payload, "input") == Map.delete(current_payload, "input")
  end

  defp list_prefix?(list, prefix) when is_list(list) and is_list(prefix) do
    length(list) >= length(prefix) and Enum.take(list, length(prefix)) == prefix
  end

  defp list_prefix?(_list, _prefix), do: false

  defp remember_completed_response(state, connection, logical_request, response) do
    %{
      state
      | connection: connection,
        last_request: logical_request,
        last_response: %{
          "id" => Map.get(response, "id"),
          "output" => Map.get(response, "output") || []
        }
    }
  end

  defp reset_transport_state(state) do
    close_connection(Map.get(state, :connection))

    %{
      state
      | connection: nil,
        last_request: nil,
        last_response: nil
    }
  end

  defp close_connection(nil), do: :ok

  defp close_connection(%{conn: conn, websocket: websocket, ref: ref}) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, :close),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      _ = websocket
      close_mint_connection(conn)
    else
      _other ->
        close_mint_connection(conn)
    end
  end

  defp close_mint_connection(nil), do: :ok

  defp close_mint_connection(conn) do
    _ = Mint.HTTP.close(conn)
    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp emit_response_error(emit, provider, logical_request, meta)
       when is_function(emit, 1) and is_map(meta) do
    emit.(
      {:response_error,
       meta
       |> rewrite_provider(provider)
       |> Map.put(:raw_request, logical_request)
       |> Map.put_new(:raw_response, nil)}
    )
  end

  defp maybe_emit_response_error(emit, provider, logical_request, meta) do
    if Map.get(meta, :already_emitted) == true do
      :ok
    else
      emit_response_error(emit, provider, logical_request, meta)
    end
  end

  defp connection_error_meta(%Mint.WebSocket.UpgradeFailureError{} = error, url) do
    %{
      status_code: error.status_code,
      url: url_string(url),
      retryable: MapSet.member?(@retryable_http_status_codes, error.status_code),
      error_kind: "http",
      error_text: Exception.message(error),
      raw_response: %{
        "status_code" => error.status_code,
        "headers" => normalize_headers(error.headers)
      }
    }
  end

  defp connection_error_meta(error, url) do
    %{
      status_code: nil,
      url: url_string(url),
      retryable: retryable_transport_error?(error),
      error_kind: transport_error_kind(error),
      error_text: error_text(error),
      raw_response: nil
    }
  end

  defp send_error_meta(error, url) do
    %{
      status_code: nil,
      url: url_string(url),
      retryable: true,
      error_kind: "network",
      error_text: error_text(error),
      raw_response: nil
    }
  end

  defp receive_error_meta(:timeout, url) do
    %{
      status_code: nil,
      url: url_string(url),
      retryable: true,
      error_kind: "timeout",
      error_text: "WebSocket receive timeout",
      raw_response: nil
    }
  end

  defp receive_error_meta(:closed, url) do
    %{
      status_code: nil,
      url: url_string(url),
      retryable: true,
      error_kind: "network",
      error_text: "WebSocket connection closed before response.completed",
      raw_response: nil
    }
  end

  defp receive_error_meta(error, url) do
    %{
      status_code: nil,
      url: url_string(url),
      retryable: retryable_transport_error?(error),
      error_kind: transport_error_kind(error),
      error_text: error_text(error),
      raw_response: nil
    }
  end

  defp frame_error_meta(error, url) do
    %{
      status_code: nil,
      url: url_string(url),
      retryable: true,
      error_kind: "transport",
      error_text: error_text(error),
      raw_response: nil
    }
  end

  defp retryable_terminal_error?(meta) when is_map(meta) do
    Map.get(meta, :retryable) == true or Map.get(meta, "retryable") == true
  end

  defp retryable_terminal_error?(_meta), do: false

  defp retryable_transport_error?(%Mint.TransportError{}), do: true
  defp retryable_transport_error?(%Mint.HTTPError{}), do: true
  defp retryable_transport_error?(%Mint.WebSocketError{}), do: true
  defp retryable_transport_error?(:timeout), do: true
  defp retryable_transport_error?(:closed), do: true

  defp retryable_transport_error?(reason) when is_atom(reason) do
    reason in [:econnrefused, :econnreset, :enetunreach, :ehostunreach, :nxdomain]
  end

  defp retryable_transport_error?(_error), do: true

  defp transport_error_kind(:timeout), do: "timeout"
  defp transport_error_kind(%Mint.TransportError{}), do: "network"
  defp transport_error_kind(%Mint.HTTPError{}), do: "transport"
  defp transport_error_kind(%Mint.WebSocketError{}), do: "transport"
  defp transport_error_kind(_error), do: "network"

  defp error_text(%{__exception__: true} = exception), do: Exception.message(exception)
  defp error_text(reason), do: inspect(reason)

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {key, value} -> {to_string(key), to_string(value)}
      other -> other
    end)
  end

  defp normalize_headers(_headers), do: []

  defp url_string(%{uri: %URI{} = uri}), do: URI.to_string(uri)
  defp url_string(%URI{} = uri), do: URI.to_string(uri)
  defp url_string(_url), do: nil

  defp stringify_keys(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_keys(nested_value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
