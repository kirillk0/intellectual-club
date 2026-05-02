defmodule IntellectualClubWeb.AshJsonApi.KnowledgeBlocksSearchTest do
  @moduledoc """
  Regression tests for knowledge block search and tag subtree filtering.
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

  defp ids_from_json(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  test "GET /api/ash/knowledge-blocks filters by tag subtree (index :search)", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    root =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Root", parent_id: nil}, actor: actor)
      |> Ash.create!(actor: actor)

    child =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Child", parent_id: root.id}, actor: actor)
      |> Ash.create!(actor: actor)

    grandchild =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Grandchild", parent_id: child.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    other =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Other", parent_id: nil}, actor: actor)
      |> Ash.create!(actor: actor)

    block_root =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block Root", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_child =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block Child", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_grandchild =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block Grandchild", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_other =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block Other", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_untagged =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block Untagged", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _root_binding =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block_root.id, knowledge_tag_id: root.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _child_binding =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block_child.id, knowledge_tag_id: child.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _grandchild_binding =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block_grandchild.id, knowledge_tag_id: grandchild.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _other_binding =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block_other.id, knowledge_tag_id: other.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    root_resp =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/knowledge-blocks?tag_id=#{root.id}&sort=name")
      |> json_response(200)

    assert ids_from_json(root_resp) ==
             Enum.sort([block_child.id, block_grandchild.id, block_root.id])

    child_resp =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/knowledge-blocks?tag_id=#{child.id}&sort=name")
      |> json_response(200)

    assert ids_from_json(child_resp) == Enum.sort([block_child.id, block_grandchild.id])

    grandchild_resp =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/knowledge-blocks?tag_id=#{grandchild.id}&sort=name")
      |> json_response(200)

    assert ids_from_json(grandchild_resp) == Enum.sort([block_grandchild.id])

    other_resp =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/knowledge-blocks?tag_id=#{other.id}&sort=name")
      |> json_response(200)

    assert ids_from_json(other_resp) == Enum.sort([block_other.id])

    untagged_resp =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/knowledge-blocks?no_tags=true&sort=name")
      |> json_response(200)

    assert ids_from_json(untagged_resp) == Enum.sort([block_untagged.id])
  end
end
