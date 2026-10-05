defmodule IntellectualClub.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.Drivers.McpHttp
  alias IntellectualClub.Tools.DriverMetadata
  alias IntellectualClub.Tools.Registry

  # {type, supports_artifacts?, supports_handoff?}
  @capabilities [
    {"mcp-http", false, false},
    {"native-agent-management", false, true},
    {"native-artifact-reader", true, false},
    {"native-game-tools", false, false},
    {"native-knowledge-library", false, false},
    {"native-web-reader", false, false},
    {"native-web-search", false, false},
    {"outlet", true, false},
    {"ssh", true, false}
  ]

  describe "Registry" do
    test "lists every canonical tool type and hides the legacy MCP HTTP type" do
      types = Registry.list_types()

      for {type, _artifacts?, _handoff?} <- @capabilities do
        assert type in types
      end

      refute "mcp_http" in types
    end

    test "resolves legacy MCP HTTP tool type for existing data" do
      assert Registry.driver_for_type!("mcp_http") == McpHttp
    end

    for {type, artifacts?, handoff?} <- @capabilities do
      @type_name type
      @artifacts? artifacts?
      @handoff? handoff?

      test "#{type} reports artifacts=#{artifacts?} and handoff=#{handoff?} consistently" do
        assert Registry.supports_artifacts?(@type_name) == @artifacts?
        assert Registry.supports_handoff?(@type_name) == @handoff?
        assert Registry.supports_handoff?(%{type: @type_name}) == @handoff?
        assert DriverMetadata.for_type(@type_name)["supports_artifacts"] == @artifacts?
      end
    end

    test "unknown types support neither artifacts nor handoff" do
      refute Registry.supports_artifacts?("unknown")
      refute Registry.supports_handoff?("unknown")
    end
  end

  describe "DriverMetadata" do
    test "list/0 reports artifact support for every driver" do
      by_type = DriverMetadata.list() |> Map.new(&{&1["type"], &1["supports_artifacts"]})

      for {type, artifacts?, _handoff?} <- @capabilities do
        assert by_type[type] == artifacts?
      end
    end

    test "artifact reader exposes default config and fixed functions" do
      metadata = DriverMetadata.for_type("native-artifact-reader")

      assert metadata["type"] == "native-artifact-reader"
      assert metadata["title"] == "Artifact Reader"
      assert metadata["functions_mode"] == "fixed"
      assert metadata["supports_artifacts"] == true
      assert metadata["default_config"]["chunk_size_tokens"] == 5_000

      assert metadata["fixed_functions"]
             |> Enum.map(& &1["name"])
             |> Enum.sort() == ["read_file", "read_image", "search_file", "upload_file"]
    end

    test "game tools expose the random_select schema" do
      metadata = DriverMetadata.for_type("native-game-tools")

      assert metadata["type"] == "native-game-tools"
      assert metadata["title"] == "Game Tools"
      assert metadata["functions_mode"] == "fixed"
      assert metadata["supports_discovery"] == false
      assert metadata["supports_artifacts"] == false

      assert %{"parameters_schema" => schema} =
               Enum.find(metadata["fixed_functions"], &(&1["name"] == "random_select"))

      assert schema["required"] == ["options"]
      assert schema["properties"]["options"]["type"] == "array"
    end

    test "agent management exposes fixed handoff, fork and sleep schemas" do
      metadata = DriverMetadata.for_type("native-agent-management")

      assert metadata["functions_mode"] == "fixed"
      assert metadata["supports_discovery"] == false
      assert metadata["supports_artifacts"] == false
      assert metadata["supports_handoff"] == true

      assert %{"parameters_schema" => schema} =
               Enum.find(metadata["fixed_functions"], &(&1["name"] == "handoff"))

      assert schema["required"] == ["summary"]
      assert schema["properties"]["summary"]["type"] == "string"

      assert %{"parameters_schema" => schema} =
               fork_function = Enum.find(metadata["fixed_functions"], &(&1["name"] == "fork"))

      assert fork_function["enabled"] == false
      assert fork_function["enabled_by_default"] == false
      assert schema["required"] == ["brief", "prompt"]
      assert schema["properties"]["prompt"]["type"] == "string"

      assert %{"parameters_schema" => schema} =
               Enum.find(metadata["fixed_functions"], &(&1["name"] == "sleep"))

      assert schema["required"] == ["seconds"]
      assert schema["properties"]["seconds"]["type"] == "number"
    end

    test "background function capabilities are normalized" do
      ssh_functions = DriverMetadata.for_type("ssh")["fixed_functions"]

      assert %{
               "is_background_function" => false,
               "provides_background_task_status" => false
             } = Enum.find(ssh_functions, &(&1["name"] == "run_command"))

      assert %{
               "is_background_function" => true,
               "provides_background_task_status" => false
             } = Enum.find(ssh_functions, &(&1["name"] == "run_command_background"))

      agent_functions = DriverMetadata.for_type("native-agent-management")["fixed_functions"]

      for name <- ["fork_background", "spawn_background"] do
        assert %{
                 "is_background_function" => true,
                 "provides_background_task_status" => false
               } = Enum.find(agent_functions, &(&1["name"] == name))
      end

      assert %{
               "is_background_function" => false,
               "provides_background_task_status" => true
             } = Enum.find(agent_functions, &(&1["name"] == "check_background_task_status"))
    end
  end
end
