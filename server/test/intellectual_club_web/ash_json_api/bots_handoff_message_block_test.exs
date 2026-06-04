defmodule IntellectualClubWeb.AshJsonApi.BotsHandoffMessageBlockTest do
  @moduledoc """
  Regression tests for the bot handoff message block setting.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Knowledge.KnowledgeBlock

  defp json_api_patch(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, body)
  end

  test "PATCH /api/ash/bots/:id saves handoff message block reference", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Handoff prompt", version: "v1", content: "Custom prompt"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    bot =
      Bot
      |> Ash.Changeset.for_create(:create, %{name: "Handoff bot"}, actor: actor)
      |> Ash.create!(actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_patch("/api/ash/bots/#{bot.id}", %{
        "data" => %{
          "type" => "bots",
          "id" => "#{bot.id}",
          "attributes" => %{
            "handoff_message_block_id" => block.id
          }
        }
      })
      |> json_response(200)

    assert get_in(response, ["data", "attributes", "handoff_message_block_id"]) == block.id
    assert Ash.get!(Bot, bot.id, actor: actor).handoff_message_block_id == block.id
  end
end
