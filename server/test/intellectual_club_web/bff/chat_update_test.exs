defmodule IntellectualClubWeb.Bff.ChatUpdateTest do
  @moduledoc """
  Chat settings BFF tests.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance

  test "GET /api/bff/chat-state/:id returns only effective active tool bindings", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot =
      Bot
      |> Ash.Changeset.for_create(:create, %{name: "Tool state bot"}, actor: actor)
      |> Ash.create!(actor: actor)

    bot_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "Bot Tool",
          alias: "web",
          config: %{"server_url" => "https://example.com/bot"},
          secrets: %{"bearer_token" => "bot"}
        },
        actor: actor
      )
      |> Ash.create!()

    chat_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Chat Tool",
          alias: "web",
          config: %{},
          secrets: %{"token" => "chat"}
        },
        actor: actor
      )
      |> Ash.create!()

    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: bot_tool.id,
        sharing_mode: :shared,
        enabled: true,
        sequence: 10
      },
      actor: actor
    )
    |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: chat_tool.id, enabled: true, sequence: 0},
      actor: actor
    )
    |> Ash.create!()

    payload =
      conn
      |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
      |> json_response(200)

    assert [%{"alias" => "web", "source" => "chat", "tool_instance" => tool_payload}] =
             payload["active_tool_bindings"]

    assert tool_payload["id"] == chat_tool.id
    assert tool_payload["name"] == "Chat Tool"
    assert tool_payload["type"] == "native-brave-search"
  end
end
