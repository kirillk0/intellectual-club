defmodule IntellectualClub.Tools.WebSearchMigrationTest do
  use IntellectualClub.DataCase, async: false
  alias IntellectualClub.Tools.{ToolInstance, ToolFunction}
  alias IntellectualClub.Tools.WebSearch.StartupMigrator
  alias IntellectualClub.Secrets.{DriverSecrets, ToolInstanceSecret}
  require Ash.Query

  test "migrates legacy config and plaintext aliases in place and is idempotent" do
    %{user: actor} = user_fixture()

    for token_name <- ~w(token api_token bearer_token) do
      legacy = legacy_tool(actor, %{token_name => "test-key"})

      function =
        ToolFunction
        |> Ash.Changeset.for_create(
          :create,
          %{
            tool_instance_id: legacy.id,
            name: "web_search",
            description: "Custom",
            parameters_schema: %{},
            enabled: false
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      assert {:ok, migrated} = StartupMigrator.migrate(legacy)
      assert migrated.id == legacy.id
      assert migrated.owner_id == legacy.owner_id
      assert migrated.alias == legacy.alias
      assert migrated.name == legacy.name
      assert migrated.max_output_tokens == 321
      assert migrated.rps_limit == legacy.rps_limit
      assert migrated.type == "native-web-search"
      assert migrated.config["providers"] == ["brave"]

      assert migrated.config["provider_options"]["brave"]["api_base_url"] ==
               "https://proxy.example.org/v1"

      assert migrated.config["timeout_seconds"] == 17
      assert migrated.config["user_agent"] == "CustomAgent"
      assert migrated.config["default_count"] == 3
      assert migrated.config["max_count"] == 7
      assert {:ok, %{"brave_api_key" => "test-key"}} = DriverSecrets.values(migrated)
      assert Ash.get!(ToolFunction, function.id, actor: actor).enabled == false
      stored = Ash.get!(ToolInstance, migrated.id, actor: actor)
      assert stored.secrets == %{}
      assert {:ok, again} = StartupMigrator.migrate(stored)
      assert again.type == migrated.type
      assert {:ok, %{"brave_api_key" => "test-key"}} = DriverSecrets.values(again)
    end
  end

  test "migrates managed bindings and keeps owner access checks" do
    %{user: actor} = user_fixture()
    %{user: other} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-web-search",
          name: "Managed",
          secrets: %{"brave_api_key" => "managed-key"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    [binding] =
      ToolInstanceSecret
      |> Ash.Query.filter(tool_instance_id == ^tool.id and kind == :driver)
      |> Ash.read!(actor: actor)

    binding
    |> Ash.Changeset.for_update(:update, %{env_name: "token"}, actor: actor)
    |> Ash.update!(actor: actor)

    legacy = legacy_update(Ash.get!(ToolInstance, tool.id, actor: actor), actor, %{})

    assert {:error, _} =
             legacy
             |> Ash.Changeset.for_update(:migrate_brave_search, %{}, actor: other)
             |> Ash.update(actor: other)

    assert {:ok, migrated} = StartupMigrator.migrate(legacy)
    assert {:ok, %{"brave_api_key" => "managed-key"}} = DriverSecrets.values(migrated)

    bindings =
      ToolInstanceSecret
      |> Ash.Query.filter(tool_instance_id == ^tool.id and kind == :driver)
      |> Ash.read!(actor: actor)

    assert Enum.map(bindings, & &1.env_name) == ["brave_api_key"]
    assert {:ok, %{migrated: 0, failed: 0}} = StartupMigrator.run()
  end

  test "migration failure leaves type and credentials intact" do
    %{user: actor} = user_fixture()
    legacy = legacy_tool(actor, %{"token" => "keep-key"})

    invalid =
      legacy
      |> Ash.Changeset.for_update(:update_discovery_metadata, %{}, actor: actor)
      |> Ash.Changeset.force_change_attribute(:config, %{"timeout_seconds" => -1})
      |> Ash.update!(actor: actor)

    assert {:error, _} = StartupMigrator.migrate(invalid)
    stored = Ash.get!(ToolInstance, legacy.id, actor: actor)
    assert stored.type == "native-brave-search"
    assert stored.secrets == %{"token" => "keep-key"}
  end

  defp legacy_tool(actor, secrets) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-web-search",
        name: "Existing Brave",
        alias: "existing_web",
        max_output_tokens: 321,
        rps_limit: 2.0
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> legacy_update(actor, secrets)
  end

  defp legacy_update(tool, actor, secrets) do
    tool
    |> Ash.Changeset.for_update(:update_discovery_metadata, %{}, actor: actor)
    |> Ash.Changeset.force_change_attribute(:type, "native-brave-search")
    |> Ash.Changeset.force_change_attribute(:config, %{
      "api_base_url" => "https://proxy.example.org/v1",
      "timeout_seconds" => 17,
      "user_agent" => "CustomAgent",
      "default_count" => 3,
      "max_count" => 7
    })
    |> Ash.Changeset.force_change_attribute(:secrets, secrets)
    |> Ash.update!(actor: actor)
  end
end
