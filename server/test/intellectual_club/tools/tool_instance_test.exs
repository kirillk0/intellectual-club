defmodule IntellectualClub.Tools.ToolInstanceTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Outlets.Auth
  alias IntellectualClub.Secrets.ToolInstanceSecret
  alias IntellectualClub.Tools.{BotToolBinding, ChatToolBinding, ToolInstance}

  require Ash.Query

  describe "aliases and bindings" do
    test "create generates, trims, validates, and allows duplicate aliases" do
      %{user: owner} = user_fixture()
      %{user: other_owner} = user_fixture()

      generated =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{type: "mcp-http", name: "Web Reader", config: mcp_config(), secrets: %{}},
          actor: owner
        )
        |> Ash.create!()

      assert generated.alias == "web_reader"

      trimmed =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "mcp-http",
            name: "Trimmed",
            alias: "  web  ",
            config: mcp_config(),
            secrets: %{}
          },
          actor: owner
        )
        |> Ash.create!()

      assert trimmed.alias == "web"

      assert {:error, _error} =
               ToolInstance
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   type: "mcp-http",
                   name: "Invalid",
                   alias: "bad__alias",
                   config: mcp_config(),
                   secrets: %{}
                 },
                 actor: owner
               )
               |> Ash.create()

      duplicate =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "mcp-http",
            name: "Duplicate",
            alias: "web",
            config: mcp_config(),
            secrets: %{}
          },
          actor: owner
        )
        |> Ash.create!()

      assert duplicate.alias == "web"

      other =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "mcp-http",
            name: "Other owner",
            alias: "web",
            config: mcp_config(),
            secrets: %{}
          },
          actor: other_owner
        )
        |> Ash.create!()

      assert other.alias == "web"
    end

    test "duplicate preserves alias" do
      %{user: owner} = user_fixture()

      source =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{type: "mcp-http", name: "Source", alias: "web", config: mcp_config(), secrets: %{}},
          actor: owner
        )
        |> Ash.create!()

      duplicated =
        ToolInstance
        |> Ash.Changeset.for_create(:duplicate, %{id: source.id}, actor: owner)
        |> Ash.create!()

      assert duplicated.alias == "web"
    end

    test "bot and chat bindings are unique by tool instance" do
      %{user: owner} = user_fixture()

      tool =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "mcp-http",
            name: "Unique tool",
            alias: "unique_tool",
            config: mcp_config(),
            secrets: %{}
          },
          actor: owner
        )
        |> Ash.create!()

      bot =
        Bot
        |> Ash.Changeset.for_create(:create, %{name: "Bot"}, actor: owner)
        |> Ash.create!(actor: owner)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: owner)
        |> Ash.create!(actor: owner)

      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, tool_instance_id: tool.id, enabled: true, sequence: 0},
        actor: owner
      )
      |> Ash.create!()

      assert {:error, _error} =
               BotToolBinding
               |> Ash.Changeset.for_create(
                 :create,
                 %{bot_id: bot.id, tool_instance_id: tool.id, enabled: true, sequence: 1},
                 actor: owner
               )
               |> Ash.create()

      ChatToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, tool_instance_id: tool.id, enabled: true, sequence: 0},
        actor: owner
      )
      |> Ash.create!()

      assert {:error, _error} =
               ChatToolBinding
               |> Ash.Changeset.for_create(
                 :create,
                 %{chat_id: chat.id, tool_instance_id: tool.id, enabled: true, sequence: 1},
                 actor: owner
               )
               |> Ash.create()
    end
  end

  describe "outlet tokens" do
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
      assert legacy.secrets == %{"token" => "legacy-token"}

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

    test "outlet auth and uniqueness fail closed when an existing token cannot be decrypted" do
      %{user: owner} = user_fixture()
      %{user: other_owner} = user_fixture()

      existing = create_outlet!(owner, "possibly-duplicated-token")

      binding =
        ToolInstanceSecret
        |> Ash.Query.filter(tool_instance_id == ^existing.id and kind == :driver)
        |> Ash.Query.load(:secret)
        |> Ash.read_one!(authorize?: false)

      binding.secret
      |> Ash.Changeset.for_update(
        :replace_encrypted,
        %{encrypted_value: <<1, 2, 3>>},
        actor: owner
      )
      |> Ash.update!(actor: owner)

      assert Auth.tool_instance_for_token("possibly-duplicated-token") == nil

      assert {:error, error} = create_outlet(other_owner, "possibly-duplicated-token")
      assert error_text(error) =~ "Existing outlet credentials could not be verified."
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
  end

  defp mcp_config do
    %{"server_url" => "https://mcp.example.com"}
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
    repo = IntellectualClub.Repo

    repo.query!("UPDATE tool_instances SET secrets = $1::text::jsonb WHERE id = $2", [
      payload,
      tool_instance_id
    ])
  end

  defp error_text(error), do: Exception.message(error)
end
