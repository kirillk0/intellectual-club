defmodule IntellectualClub.Tools.Drivers.NativeGameToolsTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.DriverMetadata
  alias IntellectualClub.Tools.Drivers.NativeGameTools
  alias IntellectualClub.Tools.ToolInstance

  @tool_instance %ToolInstance{type: "native-game-tools", config: %{}, secrets: %{}}

  test "exposes fixed random_select function" do
    functions = NativeGameTools.fixed_functions(@tool_instance)

    assert is_list(functions)
    assert Enum.any?(functions, fn spec -> Map.get(spec, "name") == "random_select" end)
  end

  test "driver metadata exposes fixed random_select function" do
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

  test "random_select returns the only positive weighted option" do
    assert {:ok, {text, raw}} =
             NativeGameTools.execute(@tool_instance, "random_select", %{
               "options" => [
                 %{"option" => "Miss", "weight" => 0},
                 %{"option" => "Hit", "weight" => 3}
               ]
             })

    assert text == "Selected option: Hit"
    assert raw["selected_option"] == "Hit"
    assert raw["selected_index"] == 2
    assert raw["total_weight"] == 3.0

    assert raw["options"] == [
             %{"index" => 1, "option" => "Miss", "weight" => 0.0},
             %{"index" => 2, "option" => "Hit", "weight" => 3.0}
           ]
  end

  test "random_select accepts two-item pair arrays" do
    assert {:ok, {_text, raw}} =
             NativeGameTools.execute(@tool_instance, "random_select", %{
               "options" => [
                 ["Left", 0],
                 ["Right", 1]
               ]
             })

    assert raw["selected_option"] == "Right"
  end

  test "random_select rejects an empty options list" do
    assert {:error, "Argument `options` must be a non-empty list."} =
             NativeGameTools.execute(@tool_instance, "random_select", %{"options" => []})
  end

  test "random_select rejects options without a positive weight" do
    assert {:error, "At least one option weight must be greater than 0."} =
             NativeGameTools.execute(@tool_instance, "random_select", %{
               "options" => [
                 %{"option" => "A", "weight" => 0},
                 %{"option" => "B", "weight" => 0}
               ]
             })
  end

  test "random_select validates option shape" do
    assert {:error, "Option 1 `option` must be a non-empty string."} =
             NativeGameTools.execute(@tool_instance, "random_select", %{
               "options" => [%{"option" => "", "weight" => 1}]
             })

    assert {:error, "Option 1 `weight` must be a non-negative number."} =
             NativeGameTools.execute(@tool_instance, "random_select", %{
               "options" => [%{"option" => "A", "weight" => -1}]
             })
  end

  test "execute rejects unknown function" do
    assert {:error, "Unknown function: unknown"} =
             NativeGameTools.execute(@tool_instance, "unknown", %{})
  end
end
