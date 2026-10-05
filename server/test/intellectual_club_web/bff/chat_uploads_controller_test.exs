defmodule IntellectualClubWeb.Bff.ChatUploadsControllerTest do
  @moduledoc """
  BFF chunked chat upload tests.
  """

  use IntellectualClubWeb.ConnCase, async: false
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Files.UploadStaging

  test "POST /api/bff/chat-uploads/:chat_id rejects files above the bot size limit", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot =
      create_artifact_bot!(actor, "Tiny upload bot", max_file_size_bytes: 4)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", bot_id: bot.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      post(conn, ~p"/api/bff/chat-uploads/#{chat.id}", %{
        "filename" => "big.txt",
        "mime_type" => "text/plain",
        "size_bytes" => 5
      })

    payload = json_response(conn, 422)
    assert payload["error"] == ~s(File "big.txt" exceeds the maximum size of 4 B.)
  end

  test "chunk upload tracks progress and rejects wrong offsets", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    bot = create_artifact_bot!(actor, "Chunk bot")

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", bot_id: bot.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    upload = create_upload!(conn, chat.id, "hello.txt", "text/plain", 11)

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-upload-offset", "0")
      |> put(~p"/api/bff/chat-uploads/#{chat.id}/#{upload["upload_id"]}/chunk", "hello ")

    payload = json_response(conn, 200)
    assert get_in(payload, ["upload", "uploaded_bytes"]) == 6
    assert get_in(payload, ["upload", "status"]) == "uploading"

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-upload-offset", "0")
      |> put(~p"/api/bff/chat-uploads/#{chat.id}/#{upload["upload_id"]}/chunk", "oops")

    payload = json_response(conn, 409)
    assert payload["next_offset"] == 6

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-upload-offset", "6")
      |> put(~p"/api/bff/chat-uploads/#{chat.id}/#{upload["upload_id"]}/chunk", "world")

    payload = json_response(conn, 200)
    assert get_in(payload, ["upload", "uploaded_bytes"]) == 11
    assert get_in(payload, ["upload", "status"]) == "uploaded"
  end

  test "DELETE /api/bff/chat-uploads/:chat_id/:upload_id removes the staged file", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    bot = create_artifact_bot!(actor, "Abort cleanup bot")

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", bot_id: bot.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    upload = create_upload!(conn, chat.id, "cleanup.txt", "text/plain", 5)
    upload_path = UploadStaging.chat_upload_path(upload["upload_id"])

    assert File.exists?(upload_path)

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> delete(~p"/api/bff/chat-uploads/#{chat.id}/#{upload["upload_id"]}")

    payload = json_response(conn, 200)
    assert get_in(payload, ["upload", "status"]) == "aborted"
    refute File.exists?(upload_path)
  end

  test "oversized chunk is rejected without advancing upload progress", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    bot = create_artifact_bot!(actor, "Oversized chunk bot")

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", bot_id: bot.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    upload =
      create_upload!(conn, chat.id, "large.bin", "application/octet-stream", 6 * 1024 * 1024)

    oversized_chunk = :binary.copy(<<0>>, upload["chunk_size_bytes"] + 1)

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-upload-offset", "0")
      |> put(~p"/api/bff/chat-uploads/#{chat.id}/#{upload["upload_id"]}/chunk", oversized_chunk)

    payload = json_response(conn, 422)
    assert payload["error"] == "Upload chunk exceeds the allowed chunk size."

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chat-uploads/#{chat.id}/#{upload["upload_id"]}")

    payload = json_response(conn, 200)
    assert get_in(payload, ["upload", "uploaded_bytes"]) == 0
    assert get_in(payload, ["upload", "status"]) == "uploading"
  end

  defp create_upload!(conn, chat_id, filename, mime_type, size_bytes) do
    conn =
      post(conn, ~p"/api/bff/chat-uploads/#{chat_id}", %{
        "filename" => filename,
        "mime_type" => mime_type,
        "size_bytes" => size_bytes
      })

    json_response(conn, 200)["upload"]
  end
end
