defmodule IntellectualClub.TestHttpServer do
  @moduledoc """
  Local HTTP servers for provider/tool integration tests.

  * `start_http_server!/2` runs any plug under Bandit on a kernel-assigned
    localhost port, supervised by the current test (`unused_port!/0` reserves
    a port nobody listens on).
  * `start_scripted_server!/2` serves scripted responses per request path and
    records the requests (see `IntellectualClub.TestHttpServer.ScriptedPlug`).
  * `sse_chunks/1`, `anthropic_sse_chunks/1` and `google_sse_chunks/1` encode
    objects as provider-specific server-sent events.

  Imported by `IntellectualClub.DataCase` and `IntellectualClubWeb.ConnCase`;
  `ExUnit.Case` modules import it explicitly.
  """

  alias IntellectualClub.TestHttpServer.ScriptedPlug

  @doc """
  Reserves a localhost TCP port on which nobody listens, for tests of refused
  connections: the port stays bound (but not listening) until the calling
  process exits, so no other server can be started on it meanwhile.
  """
  def unused_port! do
    {:ok, socket} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.bind(socket, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    {:ok, %{port: port}} = :socket.sockname(socket)
    port
  end

  @doc """
  Starts `plug` (a module, `{module, opts}` or a plug function) under Bandit on
  `127.0.0.1`, supervised by the current test. Returns `{base_url, port}`.

  The port is chosen by the kernel when the listener binds (`port: 0`), so two
  servers can never race for one port. Other options are passed to Bandit.
  """
  def start_http_server!(plug, opts \\ []) do
    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, [plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 0] ++ opts},
          id: make_ref()
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {"http://127.0.0.1:#{port}", port}
  end

  @doc """
  Starts a server that answers each request path with the next scripted
  response. Returns `{base_url, agent}`.

  `scripts` maps a request path to a list of `{status, body}` responses that
  are consumed in order. Unscripted requests get status 500.

  With the default `response: :chunked`, `body` is a binary, a list of chunks
  (e.g. from `sse_chunks/1`) or a zero-arity function returning them, sent as a
  chunked `text/event-stream` response. With `response: :json`, `body` is
  encoded with Jason and sent as `application/json`.

  Options:

    * `:response` — `:chunked` (default) or `:json`;
    * `:error_content_type` — content type of chunked responses with status
      >= 400 (default: `text/event-stream` as for successful ones);
    * `:record` — what is recorded per request: `:payload` (default, the
      decoded JSON body or `%{"raw_body" => body}`), `:request`
      (`%{headers: ..., payload: ...}`) or `:query`
      (`%{query_string: ..., headers: ...}`).

  Recorded requests are returned by `scripted_requests/2`.
  """
  def start_scripted_server!(scripts, opts \\ []) when is_map(scripts) do
    agent =
      ExUnit.Callbacks.start_supervised!({Agent, fn -> %{scripts: scripts, requests: %{}} end})

    plug_opts =
      Keyword.put(Keyword.take(opts, [:response, :error_content_type, :record]), :agent, agent)

    {base_url, _port} = start_http_server!({ScriptedPlug, plug_opts})
    {base_url, agent}
  end

  @doc "Returns the requests recorded by a scripted server for `path`, oldest first."
  def scripted_requests(agent, path) when is_pid(agent) and is_binary(path) do
    Agent.get(agent, fn state -> Map.get(state.requests, path, []) end)
  end

  @doc """
  Encodes `objects` as OpenAI-style server-sent events: one `data: <json>`
  event per object followed by `data: [DONE]`.
  """
  def sse_chunks(objects) when is_list(objects) do
    Enum.map(objects, &("data: " <> Jason.encode!(&1) <> "\n\n")) ++ ["data: [DONE]\n\n"]
  end

  @doc """
  Encodes `objects` as Anthropic Messages events: `event: <type>` plus
  `data: <json>` per object, without a terminator.
  """
  def anthropic_sse_chunks(objects) when is_list(objects) do
    Enum.map(objects, fn object ->
      type = to_string(object["type"] || object[:type])
      "event: " <> type <> "\n" <> "data: " <> Jason.encode!(object) <> "\n\n"
    end)
  end

  @doc """
  Encodes `objects` as Google Interactions events: `event: <event_type>` (default
  `"message"`) plus `data: <json>` per object, followed by `event: done`.
  """
  def google_sse_chunks(objects) when is_list(objects) do
    Enum.map(objects, fn object ->
      event_type = Map.get(object, "event_type", "message")
      "event: " <> event_type <> "\n" <> "data: " <> Jason.encode!(object) <> "\n\n"
    end) ++ ["event: done\ndata: [DONE]\n\n"]
  end
end

defmodule IntellectualClub.TestHttpServer.ScriptedPlug do
  @moduledoc """
  Plug behind `IntellectualClub.TestHttpServer.start_scripted_server!/2`.

  State (an `Agent`): `%{scripts: %{path => [{status, body}]}, requests: %{path => [recorded]}}`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    agent = Keyword.fetch!(opts, :agent)
    response = Keyword.get(opts, :response, :chunked)
    {:ok, body, conn} = read_body(conn)
    recorded = record(Keyword.get(opts, :record, :payload), conn, decode_payload(body))
    path = conn.request_path

    {status, response_body} =
      Agent.get_and_update(agent, fn state ->
        requests = Map.update(state.requests, path, [recorded], &(&1 ++ [recorded]))

        case Map.get(state.scripts, path, []) do
          [{status, response_body} | rest] ->
            {{status, response_body},
             %{state | scripts: Map.put(state.scripts, path, rest), requests: requests}}

          [] ->
            {{500, missing_script(response, path)}, %{state | requests: requests}}
        end
      end)

    send_scripted(conn, response, status, response_body, opts)
  end

  defp decode_payload(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{"raw_body" => body}
    end
  end

  defp record(:payload, _conn, payload), do: payload
  defp record(:request, conn, payload), do: %{headers: conn.req_headers, payload: payload}

  defp record(:query, conn, _payload),
    do: %{query_string: conn.query_string, headers: conn.req_headers}

  defp missing_script(:json, path), do: %{"error" => "No scripted response for #{path}"}
  defp missing_script(:chunked, path), do: "No scripted response for #{path}"

  defp send_scripted(conn, :json, status, body, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_scripted(conn, :chunked, status, chunks, opts) do
    chunks = if is_function(chunks, 0), do: chunks.(), else: chunks

    content_type =
      if status >= 400 do
        Keyword.get(opts, :error_content_type, "text/event-stream")
      else
        "text/event-stream"
      end

    conn =
      conn
      |> put_resp_content_type(content_type)
      |> send_chunked(status)

    Enum.reduce_while(List.wrap(chunks), conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end
end
