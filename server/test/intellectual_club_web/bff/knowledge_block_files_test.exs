defmodule IntellectualClubWeb.Bff.KnowledgeBlockFilesTest do
  @moduledoc """
  End-to-end tests for knowledge block file attachment transport.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockFile

  require Ash.Query

  test "knowledge block file endpoints create list download delete and clean up payloads", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    %{user: other_actor, password: other_password} = user_fixture()
    block = create_block!(actor)

    unauthorized_conn =
      conn
      |> recycle()
      |> sign_in_conn(other_actor.username, other_password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/files", %{
        "file" => upload_fixture("other.txt", "text/plain", "other")
      })

    assert unauthorized_conn.status == 404

    empty_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/files", %{
        "file" => upload_fixture("empty.txt", "text/plain", "")
      })

    assert %{"error" => "File is empty."} = json_response(empty_conn, 422)

    unnamed_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/files", %{
        "file" => upload_fixture("", "text/plain", "body")
      })

    assert %{"error" => "Filename is required."} = json_response(unnamed_conn, 422)

    first_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/files", %{
        "file" => upload_fixture("first.txt", "text/plain", "first payload")
      })

    assert %{"attachment" => first, "attachments" => [first]} = json_response(first_conn, 200)
    assert first["filename"] == "first.txt"
    assert first["mime_type"] == "text/plain"
    assert first["size_bytes"] == byte_size("first payload")
    assert first["sequence"] == 0
    assert first["enabled"] == true
    assert first["url"] == "/api/bff/knowledge-blocks/#{block.id}/files/#{first["id"]}"
    assert {:ok, first_file} = Files.get_by_external_id(first["file_id"])

    disabled_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> patch("/api/bff/knowledge-blocks/#{block.id}/files/#{first["id"]}", %{
        "enabled" => false
      })

    assert %{"attachment" => disabled_first, "attachments" => [disabled_first]} =
             json_response(disabled_conn, 200)

    assert disabled_first["id"] == first["id"]
    assert disabled_first["enabled"] == false

    second_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/files", %{
        "file" => upload_fixture("second.txt", "text/plain", "second payload")
      })

    assert %{"attachments" => [listed_first, second]} = json_response(second_conn, 200)
    assert listed_first["id"] == disabled_first["id"]
    assert listed_first["enabled"] == false
    assert second["filename"] == "second.txt"
    assert second["sequence"] == 1
    assert second["enabled"] == true

    list_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/knowledge-blocks/#{block.id}/files")

    assert %{"attachments" => [^listed_first, ^second]} = json_response(list_conn, 200)

    download_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/knowledge-blocks/#{block.id}/files/#{first["id"]}")

    assert download_conn.status == 200
    assert download_conn.resp_body == "first payload"
    assert List.first(get_resp_header(download_conn, "content-type")) =~ "text/plain"
    assert List.first(get_resp_header(download_conn, "content-disposition")) =~ "first.txt"

    delete_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> delete("/api/bff/knowledge-blocks/#{block.id}/files/#{first["id"]}")

    assert %{"attachments" => [^second]} = json_response(delete_conn, 200)
    assert {:error, :not_found} = Files.get_by_external_id(first["file_id"])
    refute FilesystemStorage.exists?(first_file.sha256)

    {:ok, second_file} = Files.get_by_external_id(second["file_id"])

    block
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
    |> Ash.destroy!(actor: actor)

    assert [] =
             KnowledgeBlockFile
             |> Ash.Query.filter(knowledge_block_id == ^block.id)
             |> Ash.read!(authorize?: false)

    assert {:error, :not_found} = Files.get_by_external_id(second["file_id"])
    refute FilesystemStorage.exists?(second_file.sha256)
  end

  test "duplicating a knowledge block duplicates logical file rows and reuses payload", %{
    conn: _conn
  } do
    %{user: actor} = user_fixture()
    block = create_block!(actor)
    {:ok, file} = Files.create_from_binary("source.txt", "text/plain", "same payload")

    KnowledgeBlockFile
    |> Ash.Changeset.for_create(
      :create,
      %{knowledge_block_id: block.id, file_id: file.id, enabled: false, sequence: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    duplicate =
      KnowledgeBlock
      |> Ash.Changeset.for_create(:duplicate, %{id: block.id}, actor: actor)
      |> Ash.create!(actor: actor)

    [source_binding] =
      KnowledgeBlockFile
      |> Ash.Query.filter(knowledge_block_id == ^block.id)
      |> Ash.Query.load([:file], strict?: true)
      |> Ash.read!(actor: actor)

    [duplicate_binding] =
      KnowledgeBlockFile
      |> Ash.Query.filter(knowledge_block_id == ^duplicate.id)
      |> Ash.Query.load([:file], strict?: true)
      |> Ash.read!(actor: actor)

    assert duplicate_binding.file_id != source_binding.file_id
    assert duplicate_binding.sequence == source_binding.sequence
    assert duplicate_binding.enabled == false
    assert duplicate_binding.file.sha256 == source_binding.file.sha256
    assert file_count(file.sha256) == 2
    assert FilesystemStorage.exists?(file.sha256)
  end

  test "upload can create a disabled knowledge block file binding", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    block = create_block!(actor)

    upload_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/files", %{
        "enabled" => "false",
        "file" => upload_fixture("disabled.txt", "text/plain", "disabled payload")
      })

    assert %{"attachment" => attachment, "attachments" => [attachment]} =
             json_response(upload_conn, 200)

    assert attachment["filename"] == "disabled.txt"
    assert attachment["enabled"] == false
  end

  defp create_block!(actor) do
    KnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Files block", version: "v1", content: "content"},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp upload_fixture(filename, content_type, body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ic-kb-file-#{System.unique_integer([:positive])}-#{String.replace(filename, ~r/[^a-zA-Z0-9_.-]/, "_")}"
      )

    File.write!(path, body)

    %Plug.Upload{
      path: path,
      filename: filename,
      content_type: content_type
    }
  end

  defp file_count(sha256) do
    StoredFile
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
