defmodule IntellectualClubWeb.Bff.ResourceImagesTest do
  @moduledoc """
  End-to-end tests for owner-scoped bot and knowledge block image transport.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Files.GarbageCollector
  alias IntellectualClub.Knowledge.KnowledgeBlock

  test "bot image endpoints upload, stream, delete, and expose image metadata in JSON:API", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Image bot",
          first_messages: [],
          max_tool_rounds: 20,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    upload_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/bots/#{bot.id}/image", %{
        "file" => plug_upload("bot.png", "image/png", png_1x1())
      })

    assert %{"image" => image} = json_response(upload_conn, 200)
    assert image["filename"] == "bot.png"
    assert image["mime_type"] == "image/png"
    assert is_binary(image["url"])
    assert is_binary(image["sha256"])

    bot = Ash.get!(Bot, bot.id, actor: actor)
    assert is_integer(bot.image_file_id)
    file_id = bot.image_file_id

    show_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/bots/#{bot.id}/image")

    assert show_conn.status == 200
    assert show_conn.resp_body == png_1x1()
    assert List.first(get_resp_header(show_conn, "content-type")) =~ "image/png"
    assert List.first(get_resp_header(show_conn, "cache-control")) == "private, no-cache"
    etag = List.first(get_resp_header(show_conn, "etag"))
    assert etag == ~s("#{image["sha256"]}")

    not_modified_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> put_req_header("if-none-match", etag)
      |> get("/api/bff/bots/#{bot.id}/image")

    assert not_modified_conn.status == 304

    show_payload =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/bots/#{bot.id}")
      |> json_response(200)

    assert get_in(show_payload, ["data", "attributes", "image", "sha256"]) == image["sha256"]

    list_payload =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/bots")
      |> json_response(200)

    listed_bot =
      Enum.find(list_payload["data"], fn item ->
        item["id"] == Integer.to_string(bot.id)
      end) || %{}

    assert get_in(listed_bot, ["attributes", "image", "sha256"]) == image["sha256"]

    delete_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> delete("/api/bff/bots/#{bot.id}/image")

    assert %{"image" => nil} = json_response(delete_conn, 200)

    bot = Ash.get!(Bot, bot.id, actor: actor)
    assert bot.image_file_id == nil

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(StoredFile, file_id, authorize?: false)

    assert {:ok, :deleted} = GarbageCollector.collect_sha256(image["sha256"])
    refute FilesystemStorage.exists?(image["sha256"])
  end

  test "knowledge block image endpoints reject unauthorized and invalid uploads, and expose image metadata",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    %{user: other_actor, password: other_password} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Image block", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    unauthorized_conn =
      conn
      |> recycle()
      |> sign_in_conn(other_actor.username, other_password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/image", %{
        "file" => plug_upload("other.png", "image/png", png_1x1())
      })

    assert unauthorized_conn.status == 404

    invalid_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/image", %{
        "file" => plug_upload("note.txt", "text/plain", "not-an-image")
      })

    assert %{"error" => _message} = json_response(invalid_conn, 422)

    upload_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/image", %{
        "file" => plug_upload("block.png", "image/png", png_1x1())
      })

    assert %{"image" => image} = json_response(upload_conn, 200)
    assert image["filename"] == "block.png"
    assert image["sha256"]

    show_conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/knowledge-blocks/#{block.id}/image")

    assert show_conn.status == 200
    assert show_conn.resp_body == png_1x1()
    assert List.first(get_resp_header(show_conn, "content-type")) =~ "image/png"

    show_payload =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/knowledge-blocks/#{block.id}")
      |> json_response(200)

    assert get_in(show_payload, ["data", "attributes", "image", "sha256"]) == image["sha256"]

    list_payload =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/knowledge-blocks")
      |> json_response(200)

    listed_block =
      Enum.find(list_payload["data"], fn item ->
        item["id"] == Integer.to_string(block.id)
      end) || %{}

    assert get_in(listed_block, ["attributes", "image", "sha256"]) == image["sha256"]
  end
end
