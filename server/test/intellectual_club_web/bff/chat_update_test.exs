defmodule IntellectualClubWeb.Bff.ChatUpdateTest do
  @moduledoc """
  Chat settings BFF tests.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolFunction
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
    assert hd(payload["active_tool_bindings"])["background_functions_unavailable"] == false
  end

  test "GET /api/bff/chat-state/:id marks bindings with gated background functions", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    outlet =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "outlet",
          name: "Background outlet",
          alias: "outlet",
          config: %{},
          secrets: %{"token" => "background-outlet-token"}
        },
        actor: actor
      )
      |> Ash.create!()

    ToolFunction
    |> Ash.Changeset.for_create(
      :create,
      %{
        tool_instance_id: outlet.id,
        name: "run_job",
        description: "Run a job.",
        parameters_schema: %{"type" => "object", "properties" => %{}},
        enabled: true
      },
      actor: actor
    )
    |> Ash.create!()

    ToolFunction
    |> Ash.Changeset.for_create(
      :create,
      %{
        tool_instance_id: outlet.id,
        name: "queue_job",
        description: "Run a job in the background.",
        parameters_schema: %{"type" => "object", "properties" => %{}},
        enabled: true,
        execution_mode: :background,
        target_function_name: "run_job"
      },
      actor: actor
    )
    |> Ash.create!()

    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: outlet.id, enabled: true, sequence: 0},
      actor: actor
    )
    |> Ash.create!()

    payload =
      conn
      |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
      |> json_response(200)

    assert [
             %{
               "alias" => "outlet",
               "background_functions_unavailable" => true,
               "tool_instance" => %{"id" => outlet_id}
             }
           ] = payload["active_tool_bindings"]

    assert outlet_id == outlet.id

    status_provider =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-agent-management",
          name: "Background status provider",
          alias: "agent",
          config: %{},
          secrets: %{}
        },
        actor: actor
      )
      |> Ash.create!()

    ToolFunction
    |> Ash.Changeset.for_create(
      :create,
      %{
        tool_instance_id: status_provider.id,
        name: "check_background_task_status",
        description: "Check a background task.",
        parameters_schema: %{"type" => "object", "properties" => %{}},
        enabled: true
      },
      actor: actor
    )
    |> Ash.create!()

    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: status_provider.id, enabled: true, sequence: 1},
      actor: actor
    )
    |> Ash.create!()

    refreshed_payload =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
      |> json_response(200)

    refute Enum.any?(
             refreshed_payload["active_tool_bindings"],
             & &1["background_functions_unavailable"]
           )
  end
end
