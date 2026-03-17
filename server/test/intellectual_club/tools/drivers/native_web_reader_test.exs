defmodule IntellectualClub.Tools.Drivers.NativeWebReaderTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Tools.Drivers.NativeWebReader
  alias IntellectualClub.Tools.ToolInstance

  test "exposes fixed read_url and search_url functions" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    functions = NativeWebReader.fixed_functions(tool_instance)

    assert is_list(functions)
    assert Enum.any?(functions, fn spec -> Map.get(spec, "name") == "read_url" end)
    assert Enum.any?(functions, fn spec -> Map.get(spec, "name") == "search_url" end)
  end

  test "execute requires url for read_url" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    assert {:error, "Argument `url` is required."} =
             NativeWebReader.execute(tool_instance, "read_url", %{})
  end

  test "execute validates page argument for read_url" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    assert {:error, "Argument `page` must be a non-negative integer (1-based)."} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "https://example.com",
               "page" => -1
             })
  end

  test "execute requires regex for search_url" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    assert {:error, "Argument `regex` is required."} =
             NativeWebReader.execute(tool_instance, "search_url", %{
               "url" => "https://example.com"
             })
  end

  test "execute rejects unknown function" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    assert {:error, "Unknown function: unknown"} =
             NativeWebReader.execute(tool_instance, "unknown", %{})
  end

  defp create_tool_instance!(actor, attrs) when is_map(attrs) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          type: "native-web-reader",
          name: "Web Reader",
          config: %{},
          secrets: %{},
          max_output_tokens: 20_000
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!()
  end
end
