defmodule IntellectualClub.Tools.DiscoveryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Tools.{Discovery, ExecutionContext, Executor, ToolFunction, ToolInstance}

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

  test "sync honors background defaults and preserves explicit enablement" do
    %{user: actor} = user_fixture()

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "outlet",
          name: "Background discovery tool",
          config: %{},
          secrets: %{"token" => "background-discovery-token"}
        },
        actor: actor
      )
      |> Ash.create!()

    spec = %{
      "name" => "run_command_background",
      "description" => "Run in background.",
      "schema" => %{"type" => "object", "properties" => %{}},
      "enabled_by_default" => false,
      "execution_mode" => "background",
      "target_function_name" => "run_command"
    }

    {_stats, [created]} = Discovery.sync_discovered_functions!(tool_instance, [spec], actor)
    assert created.enabled == false
    assert created.execution_mode == :background
    assert created.target_function_name == "run_command"

    created
    |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
    |> Ash.update!()

    {_stats, [rediscovered]} = Discovery.sync_discovered_functions!(tool_instance, [spec], actor)
    assert rediscovered.enabled == true
    assert rediscovered.execution_mode == :background
    assert rediscovered.target_function_name == "run_command"
  end

  test "semantic reuse of a real function name resets generated wrapper enablement" do
    %{user: actor} = user_fixture()

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "outlet",
          name: "Semantic background discovery tool",
          config: %{},
          secrets: %{"token" => "semantic-background-discovery-token"}
        },
        actor: actor
      )
      |> Ash.create!()

    wrapper_spec = %{
      "name" => "run_command_background",
      "description" => "Generated background wrapper.",
      "schema" => %{"type" => "object", "properties" => %{}},
      "enabled_by_default" => false,
      "execution_mode" => "background",
      "target_function_name" => "run_command"
    }

    direct_spec = %{
      "name" => "run_command_background",
      "description" => "Real provider function.",
      "schema" => %{"type" => "object", "properties" => %{}},
      "enabled_by_default" => true,
      "execution_mode" => "direct"
    }

    {_stats, [wrapper]} =
      Discovery.sync_discovered_functions!(tool_instance, [wrapper_spec], actor)

    assert wrapper.enabled == false

    wrapper
    |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
    |> Ash.update!()

    base_spec = %{
      "name" => "run_command",
      "description" => "Run a command.",
      "schema" => %{"type" => "object", "properties" => %{}},
      "enabled_by_default" => true,
      "execution_mode" => "direct"
    }

    {_stats, downgraded} =
      Discovery.sync_discovered_functions!(tool_instance, [base_spec], actor)

    assert Enum.map(downgraded, & &1.name) == ["run_command"]

    unavailable_wrapper =
      ToolFunction
      |> Ash.Query.filter(
        tool_instance_id == ^tool_instance.id and name == "run_command_background"
      )
      |> Ash.read_one!(actor: actor)

    assert unavailable_wrapper.enabled == true
    assert unavailable_wrapper.discovery_available == false

    visible_functions =
      tool_instance
      |> Ash.load!(:functions, actor: actor)
      |> Map.fetch!(:functions)

    assert Enum.map(visible_functions, & &1.name) == ["run_command"]

    unavailable_result =
      Executor.execute_llm_tool(
        %{"outlet" => tool_instance},
        "outlet__run_command_background",
        %{},
        %ExecutionContext{owner_id: actor.id}
      )

    assert unavailable_result.raw["code"] == "tool_function_disabled"

    {_stats, upgraded} =
      Discovery.sync_discovered_functions!(tool_instance, [base_spec, wrapper_spec], actor)

    restored_wrapper = Enum.find(upgraded, &(&1.name == "run_command_background"))
    assert restored_wrapper.discovery_available == true
    assert restored_wrapper.enabled == true

    {_stats, [direct]} = Discovery.sync_discovered_functions!(tool_instance, [direct_spec], actor)
    assert direct.execution_mode == :direct
    assert direct.target_function_name == nil
    assert direct.enabled == true

    {_stats, [recreated_wrapper]} =
      Discovery.sync_discovered_functions!(tool_instance, [wrapper_spec], actor)

    assert recreated_wrapper.execution_mode == :background
    assert recreated_wrapper.target_function_name == "run_command"
    assert recreated_wrapper.enabled == false
  end

  test "background metadata requires a non-empty target function" do
    %{user: actor} = user_fixture()

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "outlet",
          name: "Invalid background metadata tool",
          config: %{},
          secrets: %{"token" => "invalid-background-metadata-token"}
        },
        actor: actor
      )
      |> Ash.create!()

    changeset =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool_instance.id,
          name: "broken_background",
          description: "Broken metadata.",
          parameters_schema: %{"type" => "object"},
          enabled: false,
          execution_mode: :background,
          target_function_name: " "
        },
        actor: actor
      )

    assert {:error, error} = Ash.create(changeset, actor: actor)
    assert Exception.message(error) =~ "target_function_name"
    assert Exception.message(error) =~ "is required for background execution"

    direct_function =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool_instance.id,
          name: "direct_function",
          description: "Direct function.",
          parameters_schema: %{"type" => "object"},
          execution_mode: :direct
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:error, update_error} =
             direct_function
             |> Ash.Changeset.for_update(
               :update,
               %{execution_mode: :background, target_function_name: nil},
               actor: actor
             )
             |> Ash.update(actor: actor)

    assert Exception.message(update_error) =~ "is required for background execution"
  end
end
