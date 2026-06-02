defmodule IntellectualClub.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.Drivers.McpHttp
  alias IntellectualClub.Tools.DriverMetadata
  alias IntellectualClub.Tools.Registry

  test "lists canonical MCP HTTP tool type" do
    assert "mcp-http" in Registry.list_types()
    refute "mcp_http" in Registry.list_types()
  end

  test "lists native artifact reader tool type" do
    assert "native-artifact-reader" in Registry.list_types()
  end

  test "lists native agent management tool type" do
    assert "native-agent-management" in Registry.list_types()
  end

  test "resolves legacy MCP HTTP tool type for existing data" do
    assert Registry.driver_for_type!("mcp_http") == McpHttp
  end

  test "reports artifact support for known driver types" do
    artifact_types = ["native-artifact-reader", "ssh", "outlet"]

    non_artifact_types = [
      "mcp-http",
      "native-agent-management",
      "native-brave-search",
      "native-knowledge-library",
      "native-web-reader"
    ]

    assert Enum.all?(artifact_types, &Registry.supports_artifacts?/1)
    refute Enum.any?(non_artifact_types, &Registry.supports_artifacts?/1)
    refute Registry.supports_artifacts?("unknown")
  end

  test "reports handoff support for known driver types" do
    non_handoff_types = [
      "mcp-http",
      "native-artifact-reader",
      "native-brave-search",
      "native-knowledge-library",
      "native-web-reader",
      "outlet",
      "ssh"
    ]

    assert Registry.supports_handoff?("native-agent-management")
    assert Registry.supports_handoff?(%{type: "native-agent-management"})
    assert Registry.supports_handoff?(%{"type" => "native-agent-management"})
    refute Enum.any?(non_handoff_types, &Registry.supports_handoff?/1)
    refute Registry.supports_handoff?("unknown")
  end

  test "driver metadata exposes artifact support" do
    by_type = DriverMetadata.list() |> Map.new(&{&1["type"], &1["supports_artifacts"]})

    assert by_type["native-artifact-reader"] == true
    assert by_type["ssh"] == true
    assert by_type["outlet"] == true
    assert by_type["mcp-http"] == false
    assert by_type["native-agent-management"] == false
    assert by_type["native-brave-search"] == false
    assert by_type["native-knowledge-library"] == false
    assert by_type["native-web-reader"] == false
  end

  test "driver metadata exposes fixed handoff function" do
    metadata = DriverMetadata.for_type("native-agent-management")

    assert metadata["functions_mode"] == "fixed"
    assert metadata["supports_discovery"] == false
    assert metadata["supports_artifacts"] == false
    assert metadata["supports_handoff"] == true

    assert %{"parameters_schema" => schema} =
             Enum.find(metadata["fixed_functions"], &(&1["name"] == "handoff"))

    assert schema["required"] == ["summary"]
    assert schema["properties"]["summary"]["type"] == "string"
  end
end
