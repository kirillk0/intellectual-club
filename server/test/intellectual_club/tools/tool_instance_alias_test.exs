defmodule IntellectualClub.Tools.ToolInstanceAliasTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Tools.{BotToolBinding, ChatToolBinding, ToolInstance}

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
        %{type: "mcp-http", name: "Duplicate", alias: "web", config: mcp_config(), secrets: %{}},
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

  defp mcp_config do
    %{"server_url" => "https://mcp.example.com"}
  end
end
