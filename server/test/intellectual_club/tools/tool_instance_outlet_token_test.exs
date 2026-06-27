defmodule IntellectualClub.Tools.ToolInstanceOutletTokenTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Outlets.Auth
  alias IntellectualClub.Tools.ToolInstance

  test "outlet token is unique globally on create" do
    %{user: owner} = user_fixture()
    %{user: other_owner} = user_fixture()

    _existing = create_outlet!(owner, "shared-token")

    assert {:error, error} = create_outlet(other_owner, "shared-token")
    assert error_text(error) =~ "Outlet token is already used by another outlet."
  end

  test "outlet token validation checks bearer token and legacy token keys" do
    %{user: owner} = user_fixture()
    %{user: other_owner} = user_fixture()

    legacy = create_outlet!(owner, "legacy-token")

    write_legacy_token_secret!(legacy.id, "legacy-token")

    assert {:error, error} = create_outlet(other_owner, "legacy-token")
    assert error_text(error) =~ "Outlet token is already used by another outlet."
  end

  test "outlet token is unique globally on update" do
    %{user: owner} = user_fixture()

    _existing = create_outlet!(owner, "taken-token")
    target = create_outlet!(owner, "available-token")

    assert {:error, error} =
             target
             |> Ash.Changeset.for_update(:update, %{secrets: %{"token" => "taken-token"}},
               actor: owner
             )
             |> Ash.update()

    assert error_text(error) =~ "Outlet token is already used by another outlet."

    updated =
      target
      |> Ash.Changeset.for_update(:update, %{name: "Renamed outlet"}, actor: owner)
      |> Ash.update!()

    assert updated.name == "Renamed outlet"
  end

  test "non-outlet tools are not blocked by outlet token validation" do
    %{user: owner} = user_fixture()
    %{user: other_owner} = user_fixture()

    _outlet = create_outlet!(owner, "shared-with-mcp")

    assert {:ok, tool} =
             ToolInstance
             |> Ash.Changeset.for_create(
               :create,
               %{
                 type: "mcp-http",
                 name: "MCP HTTP",
                 config: %{"server_url" => "https://mcp.example.com"},
                 secrets: %{"token" => "shared-with-mcp"}
               },
               actor: other_owner
             )
             |> Ash.create()

    assert tool.type == "mcp-http"
  end

  test "outlet auth finds canonicalized token" do
    %{user: owner} = user_fixture()

    outlet = create_outlet!(owner, "auth-token")

    assert Auth.tool_instance_for_token("auth-token").id == outlet.id
  end

  test "duplicating an outlet clears token secrets" do
    %{user: owner} = user_fixture()

    source = create_outlet!(owner, "duplicate-token")

    duplicated =
      ToolInstance
      |> Ash.Changeset.for_create(:duplicate, %{id: source.id}, actor: owner)
      |> Ash.create!()

    assert duplicated.type == "outlet"
    assert duplicated.secrets == %{}
  end

  defp create_outlet!(actor, token) when is_binary(token) do
    {:ok, tool_instance} = create_outlet(actor, token)
    tool_instance
  end

  defp create_outlet(actor, token) when is_binary(token) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "outlet",
        name: "Outlet",
        config: %{},
        secrets: %{"token" => token}
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp write_legacy_token_secret!(tool_instance_id, token)
       when is_integer(tool_instance_id) and is_binary(token) do
    payload = Jason.encode!(%{"token" => token})
    repo = IntellectualClub.Db.repo()

    if IntellectualClub.Db.postgres?() do
      repo.query!("UPDATE tool_instances SET secrets = $1::text::jsonb WHERE id = $2", [
        payload,
        tool_instance_id
      ])
    else
      repo.query!("UPDATE tool_instances SET secrets = ? WHERE id = ?", [
        payload,
        tool_instance_id
      ])
    end
  end

  defp error_text(error), do: Exception.message(error)
end
