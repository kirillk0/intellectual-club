defmodule IntellectualClub.Tools.DiscoveryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Tools.{Discovery, ToolFunction, ToolInstance}

  require Ash.Query

  test "sync_discovered_functions! reconciles functions and preserves enabled flags" do
    %{user: actor} = user_fixture()

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "Discovery reconcile tool",
          config: %{"server_url" => "https://example.com"}
        },
        actor: actor
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(
        :update_discovery_metadata,
        %{last_discovery_error: "Previous error"},
        actor: actor
      )
      |> Ash.update!()

    _existing_a =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool_instance.id,
          name: "tool_a",
          description: "Old A",
          parameters_schema: %{"type" => "object", "properties" => %{}},
          enabled: false,
          discovered_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!()

    _existing_b =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool_instance.id,
          name: "tool_b",
          description: "Old B",
          parameters_schema: %{"type" => "object", "properties" => %{}},
          enabled: true,
          discovered_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!()

    {stats, functions} =
      Discovery.sync_discovered_functions!(
        tool_instance,
        [
          %{
            "name" => "tool_a",
            "description" => "Updated A",
            "schema" => %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}},
              "required" => ["path"]
            }
          },
          %{
            "name" => "tool_c",
            "description" => "New C",
            "schema" => %{
              "type" => "object",
              "properties" => %{"query" => %{"type" => "string"}}
            }
          }
        ],
        actor
      )

    assert stats == %{created: 1, updated: 1, deleted: 1, total: 2}

    assert Enum.map(functions, & &1.name) == ["tool_a", "tool_c"]

    tool_a = Enum.find(functions, &(&1.name == "tool_a"))
    assert tool_a.description == "Updated A"
    assert tool_a.enabled == false

    assert tool_a.parameters_schema == %{
             "type" => "object",
             "properties" => %{"path" => %{"type" => "string"}},
             "required" => ["path"]
           }

    tool_c = Enum.find(functions, &(&1.name == "tool_c"))
    assert tool_c.description == "New C"
    assert tool_c.enabled == true

    persisted_names =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^tool_instance.id)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.name)

    assert persisted_names == ["tool_a", "tool_c"]

    refreshed = Ash.get!(ToolInstance, tool_instance.id, actor: actor)
    assert %DateTime{} = refreshed.last_discovered_at
    assert refreshed.last_discovery_error == ""
  end
end
