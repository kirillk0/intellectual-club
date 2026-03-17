defmodule IntellectualClubWeb.AshJsonApi.BotToolBindingsCreateTest do
  @moduledoc """
  Regression tests for creating bot tool bindings over Ash JSON:API.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Tools.{BotToolBinding, ToolInstance}

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  test "POST /api/ash/bot-tool-bindings accepts owned tool instance id", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(:create, %{name: "Bot with tool"}, actor: actor)
      |> Ash.create!(actor: actor)

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp_http",
          name: "MCP Tool",
          config: %{"server_url" => "https://example.com/mcp"},
          secrets: %{"bearer_token" => "x"},
          max_output_tokens: 2000
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/bot-tool-bindings", %{
        "data" => %{
          "type" => "bot-tool-bindings",
          "attributes" => %{
            "bot_id" => bot.id,
            "tool_instance_id" => tool_instance.id,
            "alias" => "web",
            "sharing_mode" => "shared",
            "enabled" => true,
            "sequence" => 1
          }
        }
      })
      |> json_response(201)

    binding_id = String.to_integer(response["data"]["id"])
    binding = Ash.get!(BotToolBinding, binding_id, actor: actor)

    assert binding.bot_id == bot.id
    assert binding.tool_instance_id == tool_instance.id
    assert binding.alias == "web"

    list_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get(
        "/api/ash/bot-tool-bindings?filter[bot_id]=#{bot.id}&sort=sequence&fields[bot-tool-bindings]=alias,enabled,sequence,sharing_mode,tool_instance"
      )
      |> json_response(200)

    [row | _] = list_response["data"]
    assert row["attributes"]["tool_instance"]["id"] == tool_instance.id
  end
end
