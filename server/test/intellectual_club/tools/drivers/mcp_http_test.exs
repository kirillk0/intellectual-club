defmodule IntellectualClub.Tools.Drivers.McpHttpTest do
  use ExUnit.Case, async: false

  alias IntellectualClub.TestSupport.McpHttpJsonServer
  alias IntellectualClub.Tools.Drivers.McpHttp
  alias IntellectualClub.Tools.ToolInstance

  test "discovers tools from application/json responses" do
    tool = tool_instance(start_json_server!())

    assert {:ok, [function]} = McpHttp.discover(tool)
    assert function["name"] == "search_docs"
    assert function["description"] == "Search documents"
    assert get_in(function, ["schema", "required"]) == ["query"]
  end

  test "executes tools with application/json responses" do
    tool = tool_instance(start_json_server!())

    assert {:ok, {"Found: MCP", raw_result}} =
             McpHttp.execute(tool, "search_docs", %{"query" => "MCP"})

    assert raw_result["content"] == [%{"type" => "text", "text" => "Found: MCP"}]
  end

  test "sends open and secret headers with every MCP request" do
    server_url = start_json_server!(test_pid: self())

    tool = tool_instance(server_url, %{"X-Tenant-ID" => "tenant-42"}, %{"X-API-Key" => "secret"})

    assert {:ok, [_function]} = McpHttp.discover(tool)

    assert_request_headers("initialize", [
      {"x-api-key", "secret"},
      {"x-tenant-id", "tenant-42"}
    ])

    assert_request_headers("tools/list", [
      {"x-api-key", "secret"},
      {"x-tenant-id", "tenant-42"}
    ])

    assert {:ok, {_text, _raw_result}} =
             McpHttp.execute(tool, "search_docs", %{"query" => "headers"})

    assert_request_headers("initialize", [
      {"x-api-key", "secret"},
      {"x-tenant-id", "tenant-42"}
    ])

    assert_request_headers("tools/call", [
      {"x-api-key", "secret"},
      {"x-tenant-id", "tenant-42"}
    ])
  end

  test "system and bearer headers override configured headers" do
    server_url = start_json_server!(test_pid: self())

    tool =
      server_url
      |> tool_instance(%{"Accept" => "text/plain"}, %{"Authorization" => "Basic custom"})
      |> Map.update!(:secrets, &Map.put(&1, "bearer_token", "saved-token"))

    assert {:ok, [_function]} = McpHttp.discover(tool)

    assert_receive {:mcp_request, "initialize", headers}
    assert {"accept", "application/json, text/event-stream"} in headers
    assert {"authorization", "Bearer saved-token"} in headers
    refute {"accept", "text/plain"} in headers
    refute {"authorization", "Basic custom"} in headers
  end

  test "rejects missing secret values" do
    tool =
      %ToolInstance{
        id: System.unique_integer([:positive, :monotonic]),
        type: "mcp-http",
        config: %{
          "server_url" => "http://127.0.0.1:1",
          "open_headers" => %{},
          "secret_header_names" => ["X-Missing"]
        },
        secrets: %{"secret_headers" => %{}}
      }

    assert {:error, "Secret headers is missing a stored value for X-Missing."} =
             McpHttp.discover(tool)

    assert {:error, "Secret headers is missing a stored value for X-Missing."} =
             McpHttp.validate_config(tool, tool.config, nil)
  end

  test "rejects a header configured as both open and secret" do
    tool = tool_instance("http://127.0.0.1:1", %{"X-Tenant" => "open"}, %{"x-tenant" => "secret"})

    assert {:error, "Header x-tenant cannot be both open and secret."} =
             McpHttp.validate_config(tool, tool.config, nil)
  end

  defp tool_instance(server_url, open_headers \\ %{}, secret_headers \\ %{}) do
    %ToolInstance{
      id: System.unique_integer([:positive, :monotonic]),
      type: "mcp-http",
      config: %{
        "server_url" => server_url,
        "open_headers" => open_headers,
        "secret_header_names" => Map.keys(secret_headers)
      },
      secrets: %{"secret_headers" => secret_headers}
    }
  end

  defp start_json_server!(opts \\ []) do
    port = free_port()

    start_supervised!({Bandit, plug: {McpHttpJsonServer, opts}, scheme: :http, port: port})

    "http://127.0.0.1:#{port}"
  end

  defp assert_request_headers(method, expected_headers) do
    assert_receive {:mcp_request, ^method, headers}

    Enum.each(expected_headers, fn header ->
      assert header in headers
    end)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
