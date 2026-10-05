defmodule IntellectualClub.Tools.Drivers.NativeGameToolsTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.Drivers.NativeGameTools
  alias IntellectualClub.Tools.ToolInstance

  @tool_instance %ToolInstance{type: "native-game-tools", config: %{}, secrets: %{}}

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

  for {options, message} <- [
        {[], "Argument `options` must be a non-empty list."},
        {[%{"option" => "A", "weight" => 0}, %{"option" => "B", "weight" => 0}],
         "At least one option weight must be greater than 0."},
        {[%{"option" => "", "weight" => 1}], "Option 1 `option` must be a non-empty string."},
        {[%{"option" => "A", "weight" => -1}], "Option 1 `weight` must be a non-negative number."}
      ] do
    @options options
    @message message

    test "random_select rejects #{inspect(options)}" do
      assert {:error, @message} =
               NativeGameTools.execute(@tool_instance, "random_select", %{"options" => @options})
    end
  end
end
