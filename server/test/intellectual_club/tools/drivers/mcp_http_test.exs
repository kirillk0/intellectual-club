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

  defp tool_instance(server_url) do
    %ToolInstance{
      id: System.unique_integer([:positive, :monotonic]),
      type: "mcp-http",
      config: %{"server_url" => server_url},
      secrets: %{}
    }
  end

  defp start_json_server! do
    port = free_port()

    start_supervised!({Bandit, plug: McpHttpJsonServer, scheme: :http, port: port})

    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
