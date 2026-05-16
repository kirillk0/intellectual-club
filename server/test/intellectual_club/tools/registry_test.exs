defmodule IntellectualClub.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.Drivers.McpHttp
  alias IntellectualClub.Tools.Registry

  test "lists canonical MCP HTTP tool type" do
    assert "mcp-http" in Registry.list_types()
    refute "mcp_http" in Registry.list_types()
  end

  test "lists native artifact reader tool type" do
    assert "native-artifact-reader" in Registry.list_types()
  end

  test "resolves legacy MCP HTTP tool type for existing data" do
    assert Registry.driver_for_type!("mcp_http") == McpHttp
  end
end
