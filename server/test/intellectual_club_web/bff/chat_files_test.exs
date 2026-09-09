defmodule IntellectualClubWeb.Bff.ChatFilesTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Chat.QueuedMessages

  setup %{conn: conn} do
    account = user_fixture()
    {:ok, conn: sign_in_conn(conn, account), actor: account.user}
  end

  test "downloads an artifact by file UUID with its original name", %{conn: conn, actor: actor} do
    %{file: file} = attachment(actor, "signature.txt", "text/plain", "signature")
    conn = get(conn, file_url(file))

    assert response(conn, 200) == "signature"

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="signature.txt")
           ]

    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
  end

  test "downloads images by default and renders them inline only when requested", %{
    conn: conn,
    actor: actor
  } do
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1kAAAAASUVORK5CYII="
      )

    %{file: file} = attachment(actor, "signature.png", "image/png", png)

    download = get(conn, file_url(file))
    assert response(download, 200) == png

    assert get_resp_header(download, "content-disposition") == [
             ~s(attachment; filename="signature.png")
           ]

    inline = get(conn, file_url(file) <> "?inline=1")
    assert response(inline, 200) == png

    assert get_resp_header(inline, "content-disposition") == [
             ~s(inline; filename="signature.png")
           ]

    assert hd(get_resp_header(inline, "content-type")) =~ "image/png"

    cached =
      conn
      |> put_req_header("if-none-match", hd(get_resp_header(inline, "etag")))
      |> get(file_url(file) <> "?inline=1")

    assert response(cached, 304) == ""
  end

  test "rejects inline documents", %{conn: conn, actor: actor} do
    %{file: file} = attachment(actor, "page.html", "text/html", "<h1>Document</h1>")

    assert conn |> get(file_url(file) <> "?inline=1") |> json_response(415) ==
             %{"error" => "File is not an image"}
  end

  test "requires authentication and hides another owner's attachment", %{conn: conn} do
    %{user: other_actor} = user_fixture()
    %{file: file} = attachment(other_actor)

    assert conn |> get(file_url(file)) |> json_response(404) == %{"error" => "Not found"}

    assert build_conn() |> get(file_url(file)) |> json_response(401) == %{
             "error" => "Unauthorized"
           }
  end

  test "finds attachments in any accessible chat", %{conn: conn, actor: actor} do
    first = attachment(actor, "first.txt", "text/plain", "first")
    second = attachment(actor, "second.txt", "text/plain", "second")
    assert first.chat.id != second.chat.id

    assert conn |> get(file_url(first.file)) |> response(200) == "first"
    assert conn |> get(file_url(second.file)) |> response(200) == "second"
  end

  test "rejects malformed, missing, unbound and content UUIDs", %{conn: conn, actor: actor} do
    %{content: content} = attachment(actor)
    {:ok, unbound_file} = Files.create_from_binary("unbound.txt", "text/plain", "unbound")

    for id <- ["not-a-uuid", Ash.UUID.generate(), content.external_id, unbound_file.external_id] do
      assert conn |> get("/api/bff/chat-files/#{id}") |> json_response(404) ==
               %{"error" => "Not found"}
    end
  end

  test "returns not found after the attachment is deleted", %{conn: conn, actor: actor} do
    %{file: file, content: content} = attachment(actor)
    Ash.destroy!(content, actor: actor)

    assert conn |> get(file_url(file)) |> json_response(404) == %{"error" => "Not found"}
  end

  test "serves previewable message and queue attachments inline, keeping HTML as a download", %{
    conn: conn,
    actor: actor
  } do
    for {name, mime, disposition} <- [
          {"clip.mp4", "video/mp4", "inline"},
          {"sound.mp3", "audio/mpeg", "inline"},
          {"document.pdf", "application/pdf", "inline"},
          {"page.html", "text/html", "attachment"}
        ] do
      item = attachment(actor, name, mime, "0123456789")

      {:ok, queued} =
        QueuedMessages.enqueue_follow_up(item.chat.id, %{file_ids: [item.file.id]}, actor)

      content = Enum.find(queued.contents, &(&1.kind == :media))

      for url <- [
            content_url(item),
            "/api/bff/chat-queued-messages/#{queued.id}/contents/#{content.id}/file"
          ] do
        preview = get(conn, url)
        assert response(preview, 200) == "0123456789"

        assert get_resp_header(preview, "content-disposition") == [
                 ~s(#{disposition}; filename="#{name}")
               ]

        assert hd(get_resp_header(preview, "content-type")) =~ mime

        partial = conn |> put_req_header("range", "bytes=2-4") |> get(url)
        assert response(partial, 206) == "234"
        assert get_resp_header(partial, "content-range") == ["bytes 2-4/10"]
      end
    end
  end

  test "serves single byte ranges and ignores malformed or multipart ranges", %{
    conn: conn,
    actor: actor
  } do
    item = attachment(actor, "clip.mp4", "video/mp4", "0123456789")

    for {range, body, content_range} <- [
          {"bytes=0-1", "01", "bytes 0-1/10"},
          {"bytes=5-", "56789", "bytes 5-9/10"},
          {"bytes=-3", "789", "bytes 7-9/10"},
          {"bytes=8-100", "89", "bytes 8-9/10"},
          {"bytes=-100", "0123456789", "bytes 0-9/10"},
          {"bytes=0-9", "0123456789", "bytes 0-9/10"}
        ] do
      partial = conn |> put_req_header("range", range) |> get(content_url(item))
      assert response(partial, 206) == body
      assert get_resp_header(partial, "content-range") == [content_range]
      assert get_resp_header(partial, "accept-ranges") == ["bytes"]
    end

    for range <- [
          "bytes=",
          "bytes=-",
          "bytes=nope",
          "bytes=3-1",
          "bytes=30-20",
          "bytes=0-1,5-6",
          "items=0-1"
        ] do
      full = conn |> put_req_header("range", range) |> get(content_url(item))
      assert response(full, 200) == "0123456789"
      assert get_resp_header(full, "content-range") == []
    end

    for range <- ["bytes=10-", "bytes=100-200", "bytes=-0"] do
      invalid = conn |> put_req_header("range", range) |> get(content_url(item))
      assert response(invalid, 416) == ""
      assert get_resp_header(invalid, "content-range") == ["bytes */10"]
    end
  end

  test "honors validators and ignores Range on HEAD", %{conn: conn, actor: actor} do
    item = attachment(actor, "clip.mp4", "video/mp4", "0123456789")
    etag = ~s("#{item.file.sha256}")

    for validator <- [etag, ~s("outdated"), "W/" <> etag, "Wed, 09 Sep 2026 00:00:00 GMT"] do
      result =
        conn
        |> put_req_header("range", "bytes=2-4")
        |> put_req_header("if-range", validator)
        |> get(content_url(item))

      if validator == etag,
        do: assert(response(result, 206) == "234"),
        else: assert(response(result, 200) == "0123456789")
    end

    cached =
      conn
      |> put_req_header("range", "bytes=2-4")
      |> put_req_header("if-none-match", etag)
      |> get(content_url(item))

    assert response(cached, 304) == ""
    assert get_resp_header(cached, "content-range") == []

    result = conn |> put_req_header("range", "bytes=2-4") |> head(content_url(item))
    assert result.status == 200
    assert get_resp_header(result, "content-range") == []
  end

  test "range requests still require access to the message or queue", %{conn: conn, actor: actor} do
    item = attachment(actor, "clip.mp4", "video/mp4", "0123456789")

    {:ok, queued} =
      QueuedMessages.enqueue_follow_up(item.chat.id, %{file_ids: [item.file.id]}, actor)

    content = Enum.find(queued.contents, &(&1.kind == :media))
    outsider = user_fixture()

    for url <- [
          content_url(item),
          "/api/bff/chat-queued-messages/#{queued.id}/contents/#{content.id}/file"
        ] do
      unauthorized = build_conn() |> put_req_header("range", "bytes=0-1") |> get(url)
      assert unauthorized.status == 401

      forbidden =
        conn |> sign_in_conn(outsider) |> put_req_header("range", "bytes=0-1") |> get(url)

      assert forbidden.status in [403, 404]
    end
  end

  defp file_url(file), do: "/api/bff/chat-files/#{file.external_id}"

  defp content_url(item),
    do: "/api/bff/chat-messages/#{item.message.id}/contents/#{item.content.id}/file"

  defp attachment(actor, filename \\ "file.txt", mime_type \\ "text/plain", payload \\ "body") do
    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{chat_id: chat.id, role: :assistant, status: :done},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_id: message.id, sequence: 1, status: :done},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 1, type: :artifact},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, file} = Files.create_from_binary(filename, mime_type, payload)

    content =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_item_id: item.id, sequence: 1, kind: :media, file_id: file.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    %{chat: chat, message: message, file: file, content: content}
  end
end
