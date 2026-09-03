defmodule IntellectualClub.DriverSecretsTest do
  use IntellectualClub.DataCase, async: false

  import ExUnit.CaptureLog

  alias IntellectualClub.Repo

  alias IntellectualClub.Secrets.{
    Crypto,
    DriverSecrets,
    Secret,
    StartupMigrator,
    ToolInstanceSecret
  }

  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  setup do
    current = Application.get_env(:intellectual_club, :managed_secrets_encryption_key)
    previous = Application.get_env(:intellectual_club, :managed_secrets_previous_encryption_keys)

    on_exit(fn ->
      restore_env(:managed_secrets_encryption_key, current)
      restore_env(:managed_secrets_previous_encryption_keys, previous)
    end)

    :ok
  end

  test "effective plaintext remains redacted while validations run" do
    %{user: actor} = user_fixture()
    marker = "plaintext-private-key-marker"

    changeset =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "ssh",
          name: "Redacted SSH",
          config: %{"host" => "example.com", "username" => "root"},
          secrets: %{"private_key" => marker}
        },
        actor: actor
      )

    assert Ash.Changeset.get_attribute(changeset, :secrets) == %{}

    assert Ash.Changeset.get_argument(changeset, :effective_driver_secrets) == %{
             "private_key" => marker
           }

    refute inspect(changeset) =~ marker
    assert inspect(changeset) =~ "**redacted**"

    invalid_changeset =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "unknown-driver",
          name: "Invalid tool",
          config: %{},
          secrets: %{"private_key" => marker}
        },
        actor: actor
      )

    refute inspect(invalid_changeset) =~ marker
    assert inspect(invalid_changeset) =~ "**redacted**"
  end

  test "driver credentials are stored as encrypted bindings while the legacy column stays empty" do
    %{user: actor} = user_fixture()

    created =
      create_tool!(actor, %{
        type: "mcp-http",
        name: "Encrypted MCP",
        config: %{
          "server_url" => "https://example.com",
          "secret_header_names" => ["X-API-Key"]
        },
        secrets: %{
          "token" => "bearer-value",
          "secret_headers" => %{"X-API-Key" => "header-value"}
        }
      })

    assert created.secrets == %{
             "bearer_token" => "bearer-value",
             "secret_headers" => %{"X-API-Key" => "header-value"}
           }

    reloaded = Ash.get!(ToolInstance, created.id, actor: actor)
    assert reloaded.secrets == %{}

    bindings = driver_bindings!(created.id)
    assert Enum.map(bindings, & &1.env_name) == ["bearer_token", "secret_headers"]
    assert Enum.all?(bindings, &(&1.kind == :driver))
    assert Enum.all?(bindings, &(&1.enabled == false))

    refute Enum.any?(bindings, fn binding ->
             binding.secret.encrypted_value in ["bearer-value", "header-value"]
           end)

    assert {:ok, hydrated} = DriverSecrets.hydrate(reloaded)

    assert hydrated.secrets == %{
             "bearer_token" => "bearer-value",
             "secret_headers" => %{"X-API-Key" => "header-value"}
           }
  end

  test "driver and environment bindings may use the same name without sharing a secret" do
    %{user: actor} = user_fixture()

    tool =
      create_tool!(actor, %{
        type: "native-brave-search",
        name: "Brave",
        config: %{},
        secrets: %{"token" => "driver-token"}
      })

    environment_secret = create_secret!(actor, "Prompt token", "environment-token")

    environment_binding =
      ToolInstanceSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool.id,
          secret_id: environment_secret.id,
          env_name: "token"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    [driver_binding] = driver_bindings!(tool.id)

    assert driver_binding.env_name == environment_binding.env_name
    assert driver_binding.kind == :driver
    assert environment_binding.kind == :environment
    refute driver_binding.secret_id == environment_binding.secret_id

    environment_bindings =
      ToolInstanceSecret
      |> Ash.Query.filter(tool_instance_id == ^tool.id and kind == :environment)
      |> Ash.read!(actor: actor)

    assert Enum.map(environment_bindings, & &1.id) == [environment_binding.id]
  end

  test "driver secret updates retain omitted values and apply nested removals" do
    %{user: actor} = user_fixture()

    tool =
      create_tool!(actor, %{
        type: "mcp-http",
        name: "Patched MCP",
        config: %{
          "server_url" => "https://example.com",
          "secret_header_names" => ["X-Keep", "X-Remove"]
        },
        secrets: %{
          "bearer_token" => "remove-me",
          "secret_headers" => %{"X-Keep" => "keep", "X-Remove" => "remove"}
        }
      })

    reloaded = Ash.get!(ToolInstance, tool.id, actor: actor)

    updated =
      reloaded
      |> Ash.Changeset.for_update(
        :update,
        %{
          config: %{
            "server_url" => "https://example.com",
            "secret_header_names" => ["X-Keep", "X-Add"]
          },
          secrets: %{
            "token" => "",
            "secret_headers" => %{"X-Remove" => nil, "X-Add" => "added"}
          }
        },
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert updated.secrets == %{
             "secret_headers" => %{"X-Keep" => "keep", "X-Add" => "added"}
           }

    assert Ash.get!(ToolInstance, tool.id, actor: actor).secrets == %{}
    assert {:ok, values} = DriverSecrets.values(updated)
    assert values == updated.secrets

    assert Enum.map(driver_bindings!(tool.id), & &1.env_name) == ["secret_headers"]
  end

  test "a failed row synchronization rolls back the entire driver secret update" do
    %{user: actor} = user_fixture()

    tool =
      create_tool!(actor, %{
        type: "ssh",
        name: "Atomic SSH",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "original-password"}
      })

    reloaded = Ash.get!(ToolInstance, tool.id, actor: actor)

    assert {:error, error} =
             reloaded
             |> Ash.Changeset.for_update(
               :update,
               %{secrets: %{"invalid-driver-key" => "must-not-partially-save"}},
               actor: actor
             )
             |> Ash.update(actor: actor)

    refute Exception.message(error) =~ "must-not-partially-save"

    reloaded = Ash.get!(ToolInstance, tool.id, actor: actor)
    assert reloaded.secrets == %{}
    assert {:ok, %{"password" => "original-password"}} = DriverSecrets.values(reloaded)
    assert Enum.map(driver_bindings!(tool.id), & &1.env_name) == ["password"]
  end

  test "a newer legacy fallback wins over an existing driver row and is migrated" do
    %{user: actor} = user_fixture()

    tool =
      create_tool!(actor, %{
        type: "ssh",
        name: "Overlapping SSH",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "managed-value"}
      })

    import Ecto.Query

    {1, _rows} =
      from(instance in "tool_instances", where: instance.id == ^tool.id)
      |> Repo.update_all(set: [secrets: %{"password" => "newer-legacy-value"}])

    overlapping = Ash.get!(ToolInstance, tool.id, actor: actor)

    assert {:ok, %{"password" => "newer-legacy-value"}} =
             DriverSecrets.values(overlapping)

    assert {:ok, stats} = StartupMigrator.run()
    assert stats.backfilled == 1
    assert stats.backfill_failed == 0

    migrated = Ash.get!(ToolInstance, tool.id, actor: actor)
    assert migrated.secrets == %{}
    assert {:ok, %{"password" => "newer-legacy-value"}} = DriverSecrets.values(migrated)
  end

  test "startup maintenance backfills legacy maps and rekeys all managed secrets" do
    old_key = String.duplicate("o", 48)
    new_key = String.duplicate("n", 48)

    Application.put_env(:intellectual_club, :managed_secrets_encryption_key, old_key)
    Application.delete_env(:intellectual_club, :managed_secrets_previous_encryption_keys)

    %{user: actor} = user_fixture()
    standalone = create_secret!(actor, "Old key", "old-key-value")

    tool =
      create_tool!(actor, %{
        type: "ssh",
        name: "Legacy SSH",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{}
      })

    import Ecto.Query

    {1, _rows} =
      from(instance in "tool_instances", where: instance.id == ^tool.id)
      |> Repo.update_all(set: [secrets: %{"password" => "legacy-password"}])

    Application.put_env(:intellectual_club, :managed_secrets_encryption_key, new_key)

    Application.put_env(
      :intellectual_club,
      :managed_secrets_previous_encryption_keys,
      [old_key]
    )

    assert {:ok, stats} = StartupMigrator.run()
    assert stats.backfilled == 1
    assert stats.backfill_failed == 0
    assert stats.rekeyed == 1
    assert stats.rekey_failed == 0

    reloaded_tool = Ash.get!(ToolInstance, tool.id, actor: actor)
    assert reloaded_tool.secrets == %{}
    assert {:ok, %{"password" => "legacy-password"}} = DriverSecrets.values(reloaded_tool)

    reloaded_secret = Ash.get!(Secret, standalone.id, actor: actor)

    assert {:ok, "old-key-value", %{version: 2, current?: true}} =
             Crypto.decrypt_with_metadata(reloaded_secret.encrypted_value)

    Application.delete_env(:intellectual_club, :managed_secrets_previous_encryption_keys)
    assert {:ok, "old-key-value"} = Crypto.decrypt(reloaded_secret.encrypted_value)

    assert {:ok, second_stats} = StartupMigrator.run()
    assert second_stats.backfilled == 0
    assert second_stats.backfill_failed == 0
    assert second_stats.rekeyed == 0
    assert second_stats.rekey_failed == 0
  end

  test "failed startup backfill retains the complete legacy map for a later retry" do
    %{user: actor} = user_fixture()

    tool =
      create_tool!(actor, %{
        type: "ssh",
        name: "Invalid legacy SSH",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{}
      })

    import Ecto.Query

    legacy = %{"invalid-driver-key" => "must-remain"}

    {1, _rows} =
      from(instance in "tool_instances", where: instance.id == ^tool.id)
      |> Repo.update_all(set: [secrets: legacy])

    {{:ok, stats}, log} = with_log(fn -> StartupMigrator.run() end)
    assert stats.backfilled == 0
    assert stats.backfill_failed == 1
    assert log =~ "Legacy driver secret backfill failed"

    assert Ash.get!(ToolInstance, tool.id, actor: actor).secrets == legacy
    assert driver_bindings!(tool.id) == []
  end

  defp create_tool!(actor, attrs) do
    ToolInstance
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_secret!(actor, name, value) do
    Secret
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, description: "Test credential", value: value},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp driver_bindings!(tool_instance_id) do
    ToolInstanceSecret
    |> Ash.Query.filter(tool_instance_id == ^tool_instance_id and kind == :driver)
    |> Ash.Query.sort(env_name: :asc)
    |> Ash.Query.load(:secret)
    |> Ash.read!(authorize?: false)
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)
end
