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

  defp file_url(file), do: "/api/bff/chat-files/#{file.external_id}"

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

    %{chat: chat, file: file, content: content}
  end
end
