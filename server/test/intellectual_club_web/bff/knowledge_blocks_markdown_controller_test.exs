defmodule IntellectualClubWeb.Bff.KnowledgeBlocksMarkdownControllerTest do
  @moduledoc """
  End-to-end tests for Markdown import and export of knowledge blocks.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Knowledge.{KnowledgeBlock, KnowledgeBlockTag, KnowledgeTag}

  require Ash.Query

  @existing_id "11111111-1111-4111-8111-111111111111"
  @other_owner_id "22222222-2222-4222-8222-222222222222"
  @skip_id "33333333-3333-4333-8333-333333333333"

  test "POST /api/bff/knowledge-blocks/markdown-export returns requested blocks as Markdown ZIP",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    tag = create_tag!(actor, "Export / Unsafe:Tag?")

    exported =
      create_block!(actor, %{
        name: "Bad / Name?",
        version: "v1",
        content: "# Exported",
        tag_ids: [tag.id]
      })

    excluded =
      create_block!(actor, %{
        name: "Excluded",
        version: "v1",
        content: "hidden",
        tag_ids: [tag.id]
      })

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/zip")
      |> post("/api/bff/knowledge-blocks/markdown-export", %{
        "tag_id" => tag.id,
        "block_ids" => [exported.id]
      })

    assert conn.status == 200
    assert List.first(get_resp_header(conn, "content-type")) =~ "application/zip"
    assert List.first(get_resp_header(conn, "content-disposition")) =~ "Export UnsafeTag.zip"

    files = unzip_payload(conn.resp_body)
    assert Map.keys(files) == ["Bad Name [#{exported.external_id}].md"]
    assert files["Bad Name [#{exported.external_id}].md"] == "# Exported"
    refute Map.has_key?(files, "Excluded [#{excluded.external_id}].md")
  end

  test "preview matches external_id only within the current owner", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    %{user: other_actor} = user_fixture()
    tag = create_tag!(actor, "Import")

    existing =
      create_block!(actor, %{
        external_id: @existing_id,
        name: "Existing",
        content: "old"
      })

    _other_owner =
      create_block!(other_actor, %{
        external_id: @other_owner_id,
        name: "Other owner",
        content: "other"
      })

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/markdown-import/preview", %{
        "tag_id" => tag.id,
        "files" => [
          markdown_upload("Updated [#{@existing_id}].md", "new"),
          markdown_upload("Copied [#{@other_owner_id}].md", "copy")
        ]
      })
      |> json_response(200)

    assert [matched, unmatched] = response["items"]
    assert matched["default_action"] == "update"
    assert matched["available_actions"] == ["update", "create_new", "skip"]
    assert get_in(matched, ["existing_block", "id"]) == existing.id

    assert unmatched["default_action"] == "import"
    assert unmatched["available_actions"] == ["import", "skip"]
    assert unmatched["existing_block"] == nil
  end

  test "import applies update, import, create new, and skip decisions", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    %{user: other_actor} = user_fixture()

    selected_tag = create_tag!(actor, "Selected")
    existing_tag = create_tag!(actor, "Existing")

    existing =
      create_block!(actor, %{
        external_id: @existing_id,
        name: "Old name",
        version: "keep-me",
        content: "old",
        tag_ids: [existing_tag.id]
      })

    _other_owner =
      create_block!(other_actor, %{
        external_id: @other_owner_id,
        name: "Other owner",
        content: "other"
      })

    upload =
      zip_upload("blocks.zip", [
        {"Updated [#{@existing_id}].md", "updated content"},
        {"Variant [#{@existing_id}].md", "variant content"},
        {"Fresh.md", "fresh content"},
        {"Copied [#{@other_owner_id}].md", "copied content"},
        {"Skipped [#{@skip_id}].md", "skip content"},
        {"ignored.txt", "ignored"}
      ])

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/markdown-import", %{
        "tag_id" => selected_tag.id,
        "version" => "",
        "decisions" =>
          Jason.encode!(%{
            "0" => "update",
            "1" => "create_new",
            "2" => "import",
            "3" => "import",
            "4" => "skip"
          }),
        "files" => [upload]
      })
      |> json_response(200)

    assert response["imported"] == 4
    assert response["updated"] == 1
    assert response["created"] == 3
    assert response["skipped"] == 1

    updated = Ash.get!(KnowledgeBlock, existing.id, actor: actor)
    assert updated.name == "Updated"
    assert updated.content == "updated content"
    assert updated.version == "keep-me"

    updated_tag_ids = tag_ids_for_block(updated.id, actor)
    assert Enum.sort(updated_tag_ids) == Enum.sort([existing_tag.id, selected_tag.id])

    created_blocks =
      KnowledgeBlock
      |> Ash.Query.filter(owner_id == ^actor.id and id != ^existing.id)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(created_blocks, & &1.name) == ["Copied", "Fresh", "Variant"]

    copied = Enum.find(created_blocks, &(&1.name == "Copied"))
    assert copied.external_id == @other_owner_id

    fresh = Enum.find(created_blocks, &(&1.name == "Fresh"))
    assert fresh.external_id != nil
    assert fresh.external_id != @skip_id

    variant = Enum.find(created_blocks, &(&1.name == "Variant"))
    assert variant.external_id != @existing_id

    refute Enum.any?(created_blocks, &(&1.external_id == @skip_id))
    assert Enum.all?(created_blocks, &(tag_ids_for_block(&1.id, actor) == [selected_tag.id]))
  end

  defp create_tag!(actor, name) do
    KnowledgeTag
    |> Ash.Changeset.for_create(:create, %{name: name, parent_id: nil}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_block!(actor, attrs) do
    tag_ids = Map.get(attrs, :tag_ids, [])

    payload =
      attrs
      |> Map.drop([:tag_ids])
      |> Map.put_new(:version, "")
      |> Map.update(:tag_bindings, Enum.map(tag_ids, &%{knowledge_tag_id: &1}), fn bindings ->
        bindings
      end)

    action = if Map.has_key?(payload, :external_id), do: :import_markdown, else: :create

    KnowledgeBlock
    |> Ash.Changeset.for_create(action, payload, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp tag_ids_for_block(block_id, actor) do
    KnowledgeBlockTag
    |> Ash.Query.filter(knowledge_block_id == ^block_id)
    |> Ash.Query.sort(knowledge_tag_id: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.knowledge_tag_id)
  end

  defp markdown_upload(filename, body) do
    upload_fixture(filename, "text/markdown", body)
  end

  defp zip_upload(filename, entries) do
    files = Enum.map(entries, fn {path, body} -> {String.to_charlist(path), body} end)
    {:ok, {_name, payload}} = :zip.create(~c"blocks.zip", files, [:memory])
    upload_fixture(filename, "application/zip", payload)
  end

  defp upload_fixture(filename, content_type, body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ic-markdown-transfer-#{System.unique_integer([:positive])}-#{String.replace(filename, ~r/[^a-zA-Z0-9_.-]/, "_")}"
      )

    File.write!(path, body)

    %Plug.Upload{
      path: path,
      filename: filename,
      content_type: content_type
    }
  end

  defp unzip_payload(payload) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ic-markdown-export-#{System.unique_integer([:positive])}.zip"
      )

    File.write!(path, payload)
    {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])

    Map.new(files, fn {filename, body} -> {to_string(filename), body} end)
  end
end
