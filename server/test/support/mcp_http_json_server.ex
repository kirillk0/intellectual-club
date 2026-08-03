defmodule IntellectualClub.TestSupport.McpHttpJsonServer do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    payload = Jason.decode!(body)

    case payload["method"] do
      "initialize" ->
        respond_json(conn, payload["id"], %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{"tools" => %{"listChanged" => false}},
          "serverInfo" => %{"name" => "JSON MCP test server", "version" => "1.0"}
        })

      "tools/list" ->
        respond_json(conn, payload["id"], %{
          "tools" => [
            %{
              "name" => "search_docs",
              "description" => "Search documents",
              "inputSchema" => %{
                "type" => "object",
                "properties" => %{"query" => %{"type" => "string"}},
                "required" => ["query"]
              }
            }
          ]
        })

      "tools/call" ->
        query = get_in(payload, ["params", "arguments", "query"])

        respond_json(conn, payload["id"], %{
          "content" => [%{"type" => "text", "text" => "Found: #{query}"}]
        })

      method ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "Unsupported method: #{inspect(method)}")
    end
  end

  defp respond_json(conn, id, result) do
    response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}

    conn
    |> put_resp_header("mcp-session-id", "json-test-session")
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end
end
