defmodule IntellectualClubWeb.AshJsonApi.UserKnowledgeBlocksCrudTest do
  @moduledoc """
  Regression tests for user knowledge block bindings over Ash JSON:API.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlock

  require Ash.Query

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

  defp json_api_delete(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> delete(path)
  end

  test "POST/GET/DELETE /api/ash/user-knowledge-blocks manages current user bindings", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "User settings block", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!()

    create_payload = %{
      "data" => %{
        "type" => "user-knowledge-blocks",
        "attributes" => %{
          "knowledge_block_id" => block.id,
          "enabled" => true,
          "sequence" => 1
        }
      }
    }

    created =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/user-knowledge-blocks", create_payload)
      |> json_response(201)

    created_id = created["data"]["id"] |> to_string() |> String.to_integer()

    listed =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/user-knowledge-blocks")
      |> json_response(200)
      |> Map.get("data", [])

    assert Enum.any?(listed, fn row -> row["id"] == Integer.to_string(created_id) end)

    delete_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_delete("/api/ash/user-knowledge-blocks/#{created_id}")

    assert delete_conn.status in [200, 204]

    remaining =
      UserKnowledgeBlock
      |> Ash.Query.filter(owner_id == ^actor.id)
      |> Ash.read!(actor: actor)

    assert remaining == []
  end
end
