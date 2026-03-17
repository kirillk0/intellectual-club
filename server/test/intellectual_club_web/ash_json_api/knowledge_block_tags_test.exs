defmodule IntellectualClubWeb.AshJsonApi.KnowledgeBlockTagsTest do
  @moduledoc """
  Regression tests for JSON:API access to knowledge block tag bindings.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockTag
  alias IntellectualClub.Knowledge.KnowledgeTag

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  defp ids_from_included(%{"included" => included}, type) when is_list(included) do
    included
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp ids_from_included(_resp, _type), do: []

  test "GET /api/ash/knowledge-block-tags supports includes and sorting", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tag1 =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag One", parent_id: nil}, actor: actor)
      |> Ash.create!(actor: actor)

    tag2 =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag Two", parent_id: nil}, actor: actor)
      |> Ash.create!(actor: actor)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block", version: "v1", type: :rules, content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding1 =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, knowledge_tag_id: tag1.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding2 =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, knowledge_tag_id: tag2.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    resp =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get(
        "/api/ash/knowledge-block-tags?filter[knowledge_block_id]=#{block.id}&include=knowledge_tag&sort=created_at"
      )
      |> json_response(200)

    assert is_list(resp["data"])
    assert length(resp["data"]) == 2
    assert ids_from_included(resp, "knowledge-tags") == Enum.sort([tag1.id, tag2.id])
  end
end
