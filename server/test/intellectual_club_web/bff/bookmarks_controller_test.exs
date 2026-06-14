defmodule IntellectualClubWeb.Bff.BookmarksControllerTest do
  @moduledoc """
  Bookmark endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads

  test "POST /api/bff/chat-messages/:id/bookmark toggles state and updates /state payload", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Bookmarks chat")
    {:ok, message} = Threads.add_message_to_end(chat, :user, "Remember this", actor: actor)

    conn = post(conn, ~p"/api/bff/chat-messages/#{message.id}/bookmark", %{})
    payload = json_response(conn, 200)

    assert payload["message_id"] == message.id
    assert payload["bookmarked"] == true

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
    payload = json_response(conn, 200)

    bookmarked_message =
      Enum.find(payload["branch"] || [], fn item ->
        item["id"] == message.id
      end)

    assert bookmarked_message["bookmarked"] == true

    conn = post(conn, ~p"/api/bff/chat-messages/#{message.id}/bookmark", %{})
    payload = json_response(conn, 200)

    assert payload["bookmarked"] == false

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
    payload = json_response(conn, 200)

    bookmarked_message =
      Enum.find(payload["branch"] || [], fn item ->
        item["id"] == message.id
      end)

    assert bookmarked_message["bookmarked"] == false
  end

  test "GET /api/bff/bookmarks marks messages from inactive branches", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Bookmarks branch chat")

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

    {:ok, alpha} =
      Threads.add_message(chat, :assistant, "Alpha reply", actor: actor, parent_id: root.id)

    {:ok, _alpha_leaf} =
      Threads.add_message(chat, :user, "Alpha follow-up", actor: actor, parent_id: alpha.id)

    {:ok, beta} =
      Threads.add_message(chat, :assistant, "Beta reply", actor: actor, parent_id: root.id)

    {:ok, _beta_leaf} =
      Threads.add_message(chat, :user, "Beta follow-up", actor: actor, parent_id: beta.id)

    {:ok, _meta} = Threads.activate_branch(chat.id, alpha.id, actor)

    conn = post(conn, ~p"/api/bff/chat-messages/#{alpha.id}/bookmark", %{})
    assert json_response(conn, 200)["bookmarked"] == true

    {:ok, _meta} = Threads.activate_branch(chat.id, beta.id, actor)

    conn = get(conn, ~p"/api/bff/bookmarks")
    payload = json_response(conn, 200)
    [entry] = payload["bookmarks"] || []

    assert entry["message_id"] == alpha.id
    assert entry["inactive"] == true
    assert entry["preview"] == "Alpha reply"
    assert get_in(entry, ["chat", "id"]) == chat.id
    assert get_in(entry, ["chat", "message_count"]) == 3
  end

  defp create_chat!(actor, _title) do
    Chat
    |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
    |> Ash.create!(actor: actor)
  end
end
