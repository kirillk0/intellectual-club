Code.require_file(
  Path.expand(
    "../../../../priv/repo/migrations/20260716120000_rename_agent_management_subchat_config.exs",
    __DIR__
  )
)

defmodule IntellectualClub.Repo.Migrations.RenameAgentManagementSubchatConfigTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Repo.Migrations.RenameAgentManagementSubchatConfig, as: Migration
  alias IntellectualClub.Tools.ToolInstance

  test "up renames legacy keys, prefers existing new values, and leaves unrelated config intact" do
    %{user: actor} = user_fixture()

    legacy = create_tool_instance!(actor, "legacy")
    conflict = create_tool_instance!(actor, "conflict")
    already_current = create_tool_instance!(actor, "already-current")
    absent = create_tool_instance!(actor, "absent")
    unrelated = create_tool_instance!(actor, "unrelated", "native-web-reader")

    put_config!(legacy.id, %{
      "nested_forks_limit" => 2,
      "allow_handoff_in_forks" => true,
      "keep" => "legacy"
    })

    put_config!(conflict.id, %{
      "nested_forks_limit" => 1,
      "nested_subchats_limit" => 4,
      "allow_handoff_in_forks" => false,
      "allow_handoff_in_subchats" => true,
      "keep" => "conflict"
    })

    put_config!(absent.id, %{"keep" => "absent"})
    put_config!(already_current.id, %{"nested_subchats_limit" => 6, "keep" => "current"})
    put_config!(unrelated.id, %{"nested_forks_limit" => 9, "keep" => "unrelated"})

    run_statements!(Migration.up_statements())

    assert config!(legacy.id) == %{
             "nested_subchats_limit" => 2,
             "allow_handoff_in_subchats" => true,
             "keep" => "legacy"
           }

    assert config!(conflict.id) == %{
             "nested_subchats_limit" => 4,
             "allow_handoff_in_subchats" => true,
             "keep" => "conflict"
           }

    assert config!(absent.id) == %{"keep" => "absent"}
    assert config!(already_current.id) == %{"nested_subchats_limit" => 6, "keep" => "current"}
    assert config!(unrelated.id) == %{"nested_forks_limit" => 9, "keep" => "unrelated"}
  end

  test "down renames new keys, prefers existing legacy values, and leaves missing keys absent" do
    %{user: actor} = user_fixture()

    current = create_tool_instance!(actor, "current")
    conflict = create_tool_instance!(actor, "down-conflict")
    already_legacy = create_tool_instance!(actor, "already-legacy")
    absent = create_tool_instance!(actor, "down-absent")

    put_config!(current.id, %{
      "nested_subchats_limit" => 3,
      "allow_handoff_in_subchats" => true,
      "keep" => "current"
    })

    put_config!(conflict.id, %{
      "nested_forks_limit" => 7,
      "nested_subchats_limit" => 5,
      "allow_handoff_in_forks" => false,
      "allow_handoff_in_subchats" => true,
      "keep" => "conflict"
    })

    put_config!(absent.id, %{"keep" => "absent"})
    put_config!(already_legacy.id, %{"nested_forks_limit" => 8, "keep" => "legacy"})

    run_statements!(Migration.down_statements())

    assert config!(current.id) == %{
             "nested_forks_limit" => 3,
             "allow_handoff_in_forks" => true,
             "keep" => "current"
           }

    assert config!(conflict.id) == %{
             "nested_forks_limit" => 7,
             "allow_handoff_in_forks" => false,
             "keep" => "conflict"
           }

    assert config!(absent.id) == %{"keep" => "absent"}
    assert config!(already_legacy.id) == %{"nested_forks_limit" => 8, "keep" => "legacy"}
  end

  defp create_tool_instance!(actor, suffix, type \\ "native-agent-management") do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: type,
        name: "Migration #{suffix}",
        description: "",
        alias: "migration_#{suffix}_#{System.unique_integer([:positive])}",
        config: %{},
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp put_config!(id, config) do
    Repo.query!("UPDATE tool_instances SET config = $1::jsonb WHERE id = $2", [config, id])
  end

  defp config!(id) do
    %{rows: [[config]]} = Repo.query!("SELECT config FROM tool_instances WHERE id = $1", [id])
    config
  end

  defp run_statements!(statements) do
    Enum.each(statements, &Repo.query!/1)
  end
end
