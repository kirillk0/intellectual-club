defmodule IntellectualClubWeb.Bff.ChatMessageTreeTest do
  @moduledoc """
  Message tree endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads

  test "GET /api/bff/chat-state/:id/message-tree returns active and inactive messages", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

    {:ok, active} =
      Threads.add_message(chat, :assistant, "Active answer", actor: actor, parent_id: root.id)

    {:ok, inactive} =
      Threads.add_message(chat, :assistant, "Inactive answer", actor: actor, parent_id: root.id)

    {:ok, inactive_child} =
      Threads.add_message(chat, :user, "Inactive follow-up", actor: actor, parent_id: inactive.id)

    {:ok, active_child} =
      Threads.add_message(chat, :user, "Active follow-up", actor: actor, parent_id: active.id)

    {:ok, _meta} = Threads.activate_branch(chat.id, active_child.id, actor)

    conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}/message-tree")
    payload = json_response(conn, 200)
    messages = payload["messages"] || []
    messages_by_id = Map.new(messages, fn message -> {message["id"], message} end)

    assert Enum.map(messages, & &1["id"]) == [
             root.id,
             active.id,
             active_child.id,
             inactive.id,
             inactive_child.id
           ]

    assert payload["active_message_ids"] == [root.id, active.id, active_child.id]
    assert messages_by_id[active.id]["active"] == true
    assert messages_by_id[inactive.id]["active"] == false
    assert messages_by_id[inactive.id]["parent_id"] == root.id
    assert text_content(messages_by_id[inactive.id]) =~ "Inactive answer"
  end

  defp text_content(message) do
    message
    |> get_in(["content", "parts"])
    |> List.wrap()
    |> Enum.map_join("\n", &to_string(&1["text"] || ""))
  end
end
