defmodule IntellectualClubWeb.Bff.ChatUploadsControllerTest do
  @moduledoc """
  BFF chunked chat upload tests.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Tools.{BotToolBinding, ToolInstance}

  test "POST /api/bff/chats/:chat_id/uploads rejects files above the bot size limit", %{
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
      post(conn, ~p"/api/bff/chats/#{chat.id}/uploads", %{
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
      |> put(~p"/api/bff/chats/#{chat.id}/uploads/#{upload["upload_id"]}/chunk", "hello ")

    payload = json_response(conn, 200)
    assert get_in(payload, ["upload", "uploaded_bytes"]) == 6
    assert get_in(payload, ["upload", "status"]) == "uploading"

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-upload-offset", "0")
      |> put(~p"/api/bff/chats/#{chat.id}/uploads/#{upload["upload_id"]}/chunk", "oops")

    payload = json_response(conn, 409)
    assert payload["next_offset"] == 6

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-upload-offset", "6")
      |> put(~p"/api/bff/chats/#{chat.id}/uploads/#{upload["upload_id"]}/chunk", "world")

    payload = json_response(conn, 200)
    assert get_in(payload, ["upload", "uploaded_bytes"]) == 11
    assert get_in(payload, ["upload", "status"]) == "uploaded"
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
      |> put(~p"/api/bff/chats/#{chat.id}/uploads/#{upload["upload_id"]}/chunk", oversized_chunk)

    payload = json_response(conn, 422)
    assert payload["error"] == "Upload chunk exceeds the allowed chunk size."

    conn =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chats/#{chat.id}/uploads/#{upload["upload_id"]}")

    payload = json_response(conn, 200)
    assert get_in(payload, ["upload", "uploaded_bytes"]) == 0
    assert get_in(payload, ["upload", "status"]) == "uploading"
  end

  defp create_upload!(conn, chat_id, filename, mime_type, size_bytes) do
    conn =
      post(conn, ~p"/api/bff/chats/#{chat_id}/uploads", %{
        "filename" => filename,
        "mime_type" => mime_type,
        "size_bytes" => size_bytes
      })

    json_response(conn, 200)["upload"]
  end

  defp create_artifact_bot!(actor, name, attrs \\ []) do
    bot = create_bot!(actor, name, attrs)
    tool = create_artifact_tool!(actor, "#{name} Artifact Reader")
    bind_tool_to_bot!(actor, bot, tool)
    bot
  end

  defp create_bot!(actor, name, attrs) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        max_tool_rounds: 20,
        context_soft_limit_percent: 80,
        history_mode: :chat,
        max_file_size_bytes: Keyword.get(attrs, :max_file_size_bytes, 500 * 1024 * 1024)
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_artifact_tool!(actor, name) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-artifact-reader",
        name: name,
        alias: "artifacts",
        config: %{},
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp bind_tool_to_bot!(actor, bot, tool) do
    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: tool.id,
        sharing_mode: :shared,
        enabled: true,
        sequence: 0
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
