defmodule IntellectualClubWeb.AshJsonApi.KnowledgeBlocksTagBindingsManagementTest do
  @moduledoc """
  Regression tests for managing tag bindings through the knowledge block update action.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockTag
  alias IntellectualClub.Knowledge.KnowledgeTag

  require Ash.Query

  @knowledge_block_include_query "include=tag_bindings.knowledge_tag"

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  defp json_api_patch(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, body)
  end

  defp relationship_ids(%{"data" => %{"relationships" => relationships}}, rel_name) do
    relationships
    |> Map.get(rel_name, %{})
    |> Map.get("data", [])
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp relationship_ids(_resp, _rel_name), do: []

  defp ids_from_included(%{"included" => included}, type) when is_list(included) do
    included
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp ids_from_included(_resp, _type), do: []

  test "GET /api/ash/knowledge-blocks/:id includes tag bindings and tags", %{conn: conn} do
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
        %{name: "Block", version: "v1", type: :rules, content: "x", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    binding1 =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, knowledge_tag_id: tag1.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    binding2 =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, knowledge_tag_id: tag2.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/knowledge-blocks/#{block.id}?#{@knowledge_block_include_query}")
      |> json_response(200)

    assert relationship_ids(response, "tag_bindings") == Enum.sort([binding1.id, binding2.id])
    assert ids_from_included(response, "knowledge-tags") == Enum.sort([tag1.id, tag2.id])
  end

  test "PATCH /api/ash/knowledge-blocks/:id manages tag bindings", %{conn: conn} do
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
        %{name: "Block", version: "v1", type: :rules, content: "x", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)

    resp1 =
      conn
      |> json_api_patch("/api/ash/knowledge-blocks/#{block.id}?#{@knowledge_block_include_query}", %{
        "data" => %{
          "type" => "knowledge-blocks",
          "id" => "#{block.id}",
          "attributes" => %{
            "tag_bindings" => [
              %{"knowledge_tag_id" => tag1.id},
              %{"knowledge_tag_id" => tag2.id}
            ]
          }
        }
      })
      |> json_response(200)

    bindings1 =
      KnowledgeBlockTag
      |> Ash.Query.filter(knowledge_block_id == ^block.id)
      |> Ash.read!(actor: actor)

    assert Enum.sort(Enum.map(bindings1, & &1.knowledge_tag_id)) == Enum.sort([tag1.id, tag2.id])
    assert relationship_ids(resp1, "tag_bindings") == Enum.sort(Enum.map(bindings1, & &1.id))
    assert ids_from_included(resp1, "knowledge-tags") == Enum.sort([tag1.id, tag2.id])

    binding1 = Enum.find(bindings1, &(&1.knowledge_tag_id == tag1.id))
    assert binding1

    resp2 =
      conn
      |> json_api_patch("/api/ash/knowledge-blocks/#{block.id}?#{@knowledge_block_include_query}", %{
        "data" => %{
          "type" => "knowledge-blocks",
          "id" => "#{block.id}",
          "attributes" => %{
            "tag_bindings" => [
              %{"id" => binding1.id, "knowledge_tag_id" => tag1.id}
            ]
          }
        }
      })
      |> json_response(200)

    bindings2 =
      KnowledgeBlockTag
      |> Ash.Query.filter(knowledge_block_id == ^block.id)
      |> Ash.read!(actor: actor)

    assert Enum.map(bindings2, & &1.knowledge_tag_id) == [tag1.id]
    assert relationship_ids(resp2, "tag_bindings") == Enum.map(bindings2, & &1.id)
    assert ids_from_included(resp2, "knowledge-tags") == [tag1.id]
  end
end
