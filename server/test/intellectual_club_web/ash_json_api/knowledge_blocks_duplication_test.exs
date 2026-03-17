defmodule IntellectualClubWeb.AshJsonApi.KnowledgeBlocksDuplicationTest do
  @moduledoc """
  Regression tests for knowledge block duplication through Ash JSON:API endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockTag
  alias IntellectualClub.Knowledge.KnowledgeTag

  require Ash.Query

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  test "POST /api/ash/knowledge-blocks/:id/duplicate duplicates block and tag bindings", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    tag_a =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag A"}, actor: actor)
      |> Ash.create!(actor: actor)

    tag_b =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag B"}, actor: actor)
      |> Ash.create!(actor: actor)

    source =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Source block",
          version: "v1",
          type: :rules,
          content: "Important content",
          variables: %{"k" => "v"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding_a =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: source.id, knowledge_tag_id: tag_a.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding_b =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: source.id, knowledge_tag_id: tag_b.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/knowledge-blocks/#{source.id}/duplicate", %{
        "data" => %{
          "type" => "knowledge-blocks",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated_id = String.to_integer(response["data"]["id"])

    duplicated =
      KnowledgeBlock
      |> Ash.get!(duplicated_id, actor: actor)

    assert duplicated.id != source.id
    assert duplicated.owner_id == source.owner_id
    assert duplicated.name == source.name
    assert duplicated.version == "v1 copy"
    assert duplicated.type == source.type
    assert duplicated.content == source.content
    assert duplicated.variables == source.variables
    assert duplicated.token_count == source.token_count

    source_tag_ids =
      KnowledgeBlockTag
      |> Ash.Query.filter(knowledge_block_id == ^source.id)
      |> Ash.Query.sort(knowledge_tag_id: :asc)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.knowledge_tag_id)

    duplicated_tag_ids =
      KnowledgeBlockTag
      |> Ash.Query.filter(knowledge_block_id == ^duplicated_id)
      |> Ash.Query.sort(knowledge_tag_id: :asc)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.knowledge_tag_id)

    assert duplicated_tag_ids == source_tag_ids
  end

  test "POST /api/ash/knowledge-blocks/:id/duplicate creates a new image file row with the same payload",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()

    assert {:ok, source_file} =
             Files.create_from_upload(%{
               filename: "block.png",
               mime_type: "image/png",
               payload: image_payload()
             })

    source =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Image block", version: "v1", type: :rules, content: "Important content"},
        actor: actor
      )
      |> Ash.create!(actor: actor)
      |> then(fn block ->
        block
        |> Ash.Changeset.for_update(
          :attach_image_file,
          %{image_file_id: source_file.id},
          actor: actor
        )
        |> Ash.update!(actor: actor)
      end)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/knowledge-blocks/#{source.id}/duplicate", %{
        "data" => %{
          "type" => "knowledge-blocks",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated = Ash.get!(KnowledgeBlock, String.to_integer(response["data"]["id"]), actor: actor)

    assert duplicated.image_file_id != source.image_file_id
    assert is_integer(duplicated.image_file_id)

    duplicated_file = Ash.get!(StoredFile, duplicated.image_file_id, authorize?: false)

    assert duplicated_file.sha256 == source_file.sha256
    assert duplicated_file.filename == source_file.filename
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
