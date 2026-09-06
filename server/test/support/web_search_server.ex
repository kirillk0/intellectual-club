defmodule IntellectualClub.TestSupport.WebSearchServer do
  @moduledoc false
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    conn = fetch_query_params(conn)
    {:ok, body, conn} = read_body(conn)
    payload = if body == "", do: conn.query_params, else: Jason.decode!(body)
    send(opts[:test_pid], {:web_request, conn.request_path, payload, conn.req_headers})

    case opts[:handler].(conn.request_path, payload) do
      {:wait, pid} ->
        send(pid, {:waiting, self()})

        receive do
          :continue -> send_resp(conn, 200, "{}")
        after
          5000 -> send_resp(conn, 504, "timeout")
        end

      {status, content_type, text} ->
        conn |> put_resp_content_type(content_type) |> send_resp(status, text)

      {status, response} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(response))
    end
  end
end
