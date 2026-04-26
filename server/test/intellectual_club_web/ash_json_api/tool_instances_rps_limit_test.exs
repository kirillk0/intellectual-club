defmodule IntellectualClubWeb.AshJsonApi.ToolInstancesRpsLimitTest do
  @moduledoc """
  Regression tests for tool instance RPS limit management through Ash JSON:API.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Tools.{BotToolBinding, ToolInstance}

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  defp json_api_patch(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, body)
  end

  test "create and update accept positive and null rps_limit values", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/tool-instances", %{
        "data" => %{
          "type" => "tool-instances",
          "attributes" => %{
            "type" => "mcp_http",
            "name" => "Limited tool",
            "config" => %{"server_url" => "https://example.com/mcp"},
            "secrets" => %{"bearer_token" => "x"},
            "max_output_tokens" => 1000,
            "rps_limit" => 0.5
          }
        }
      })
      |> json_response(201)

    tool_id = String.to_integer(response["data"]["id"])
    assert response["data"]["attributes"]["rps_limit"] == 0.5

    assert Ash.get!(ToolInstance, tool_id, actor: actor).rps_limit == 0.5

    null_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_patch("/api/ash/tool-instances/#{tool_id}", %{
        "data" => %{
          "type" => "tool-instances",
          "id" => Integer.to_string(tool_id),
          "attributes" => %{"rps_limit" => nil}
        }
      })
      |> json_response(200)

    assert is_nil(null_response["data"]["attributes"]["rps_limit"])
    assert is_nil(Ash.get!(ToolInstance, tool_id, actor: actor).rps_limit)

    update_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_patch("/api/ash/tool-instances/#{tool_id}", %{
        "data" => %{
          "type" => "tool-instances",
          "id" => Integer.to_string(tool_id),
          "attributes" => %{"rps_limit" => 1.25}
        }
      })
      |> json_response(200)

    assert update_response["data"]["attributes"]["rps_limit"] == 1.25
    assert Ash.get!(ToolInstance, tool_id, actor: actor).rps_limit == 1.25
  end

  test "zero and negative rps_limit values are rejected", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    tool = create_tool!(actor, "Validated tool", nil)

    zero_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_patch("/api/ash/tool-instances/#{tool.id}", %{
        "data" => %{
          "type" => "tool-instances",
          "id" => Integer.to_string(tool.id),
          "attributes" => %{"rps_limit" => 0}
        }
      })

    assert zero_conn.status in [400, 422]

    negative_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_patch("/api/ash/tool-instances/#{tool.id}", %{
        "data" => %{
          "type" => "tool-instances",
          "id" => Integer.to_string(tool.id),
          "attributes" => %{"rps_limit" => -0.5}
        }
      })

    assert negative_conn.status in [400, 422]
  end

  test "shared read exposes rps_limit but shared users cannot update it", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    tool = create_tool!(owner, "Shared limited tool", 0.5)
    bot = create_bot!(owner, "Shared limited bot")
    share_tool_through_bot!(owner, bot, tool)
    share_bot!(owner, bot, group)

    attrs =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_get("/api/ash/tool-instances/#{tool.id}?fields[tool-instances]=rps_limit")
      |> json_response(200)
      |> get_in(["data", "attributes"])

    assert attrs["rps_limit"] == 0.5

    update_conn =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_patch("/api/ash/tool-instances/#{tool.id}", %{
        "data" => %{
          "type" => "tool-instances",
          "id" => Integer.to_string(tool.id),
          "attributes" => %{"rps_limit" => 2.0}
        }
      })

    assert update_conn.status in [403, 404]
  end

  defp create_tool!(actor, name, rps_limit) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "mcp_http",
        name: name,
        config: %{"server_url" => "https://example.com/mcp"},
        secrets: %{"bearer_token" => "x"},
        max_output_tokens: 1000,
        rps_limit: rps_limit
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
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
