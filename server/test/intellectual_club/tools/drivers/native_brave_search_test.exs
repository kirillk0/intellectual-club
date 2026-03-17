defmodule IntellectualClub.Tools.Drivers.NativeBraveSearchTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Tools.Drivers.NativeBraveSearch
  alias IntellectualClub.Tools.ToolInstance

  test "exposes fixed web_search function" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-brave-search", config: %{}, secrets: %{}})

    functions = NativeBraveSearch.fixed_functions(tool_instance)

    assert is_list(functions)
    assert Enum.any?(functions, fn spec -> Map.get(spec, "name") == "web_search" end)
  end

  test "execute requires token for web_search" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-brave-search", config: %{}, secrets: %{}})

    assert {:error, message} =
             NativeBraveSearch.execute(tool_instance, "web_search", %{"query" => "elixir"})

    assert String.contains?(String.downcase(message), "token")
  end

  test "execute requires query for web_search" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "native-brave-search",
        config: %{},
        secrets: %{"token" => "brave-token"}
      })

    assert {:error, message} = NativeBraveSearch.execute(tool_instance, "web_search", %{})
    assert String.contains?(message, "Argument `query` is required.")
  end

  test "execute rejects unknown function" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-brave-search", config: %{}, secrets: %{}})

    assert {:error, "Unknown function: unknown"} =
             NativeBraveSearch.execute(tool_instance, "unknown", %{})
  end

  defp create_tool_instance!(actor, attrs) when is_map(attrs) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          type: "native-brave-search",
          name: "Brave Search",
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
