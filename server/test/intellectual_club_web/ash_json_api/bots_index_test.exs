defmodule IntellectualClubWeb.AshJsonApi.BotsIndexTest do
  @moduledoc """
  Regression tests for bot list payloads.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotKnowledgeBlock}
  alias IntellectualClub.Knowledge.KnowledgeBlock

  test "GET /api/ash/bots exposes blocks_count", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    bot_with_blocks = create_bot!(actor, "Bot with blocks")
    empty_bot = create_bot!(actor, "Empty bot")
    block_one = create_block!(actor, "Block one")
    block_two = create_block!(actor, "Block two")

    create_binding!(actor, bot_with_blocks.id, block_one.id, 0)
    create_binding!(actor, bot_with_blocks.id, block_two.id, 1)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/bots?fields[bots]=name,blocks_count")
      |> json_response(200)

    bots_by_id =
      Map.new(response["data"], fn item ->
        {item["id"], item}
      end)

    assert get_in(bots_by_id, ["#{bot_with_blocks.id}", "attributes", "blocks_count"]) == 2
    assert get_in(bots_by_id, ["#{empty_bot.id}", "attributes", "blocks_count"]) == 0
  end

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
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
    |> Ash.create!(actor: actor)
  end

  defp create_block!(actor, name) do
    KnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, version: "v1", type: :rules, content: "content", variables: %{}},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_binding!(actor, bot_id, block_id, sequence) do
    BotKnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot_id, knowledge_block_id: block_id, enabled: true, sequence: sequence},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
