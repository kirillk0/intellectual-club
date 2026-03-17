defmodule IntellectualClubWeb.AshJsonApi.ToolInstancesDuplicationTest do
  @moduledoc """
  Regression tests for tool instance duplication through Ash JSON:API endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Tools.{BotToolBinding, ToolFunction, ToolInstance}

  require Ash.Query

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  test "POST /api/ash/tool-instances/:id/duplicate preserves secrets for owner copies", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    source = create_tool!(actor, "Owner tool")
    function = create_tool_function!(actor, source, "search")

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/tool-instances/#{source.id}/duplicate", %{
        "data" => %{
          "type" => "tool-instances",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated_id = String.to_integer(response["data"]["id"])
    duplicated = Ash.get!(ToolInstance, duplicated_id, actor: actor)

    duplicated_functions =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^duplicated_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(actor: actor)

    assert duplicated.owner_id == actor.id
    assert duplicated.config == source.config
    assert duplicated.secrets == source.secrets
    assert duplicated.max_output_tokens == source.max_output_tokens
    assert Enum.map(duplicated_functions, & &1.name) == [function.name]
  end

  test "POST /api/ash/tool-instances/:id/duplicate clears secrets for shared copies", %{
    conn: conn
  } do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    source = create_tool!(owner, "Shared tool")
    function = create_tool_function!(owner, source, "search")
    bot = create_bot!(owner, "Shared bot")
    share_tool_through_bot!(owner, bot, source)
    share_bot!(owner, bot, group)

    response =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_post("/api/ash/tool-instances/#{source.id}/duplicate", %{
        "data" => %{
          "type" => "tool-instances",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated_id = String.to_integer(response["data"]["id"])
    duplicated = Ash.get!(ToolInstance, duplicated_id, actor: recipient)

    duplicated_functions =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^duplicated_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(actor: recipient)

    assert duplicated.owner_id == recipient.id
    assert duplicated.config == source.config
    assert duplicated.secrets == %{}
    assert duplicated.max_output_tokens == source.max_output_tokens
    assert Enum.map(duplicated_functions, & &1.name) == [function.name]
  end

  defp create_bot!(actor, name) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        variables: %{},
        max_tool_rounds: 20,
        context_soft_limit_percent: 80,
        history_mode: :chat
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_tool!(actor, name) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "mcp_http",
        name: name,
        config: %{"server_url" => "https://example.com/mcp"},
        secrets: %{"bearer_token" => "super-secret"},
        max_output_tokens: 1000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_tool_function!(actor, tool, name) do
    ToolFunction
    |> Ash.Changeset.for_create(
      :create,
      %{
        tool_instance_id: tool.id,
        name: name,
        description: "Search",
        parameters_schema: %{"type" => "object"},
        enabled: true,
        discovered_at: DateTime.utc_now()
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp share_tool_through_bot!(actor, bot, tool) do
    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: tool.id,
        alias: "shared_tool",
        sharing_mode: :shared,
        enabled: true,
        sequence: 0
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!()
  end
end
