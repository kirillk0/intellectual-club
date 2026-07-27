defmodule IntellectualClubWeb.Bff.ChatQueuedMessagesControllerTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads

  test "queue CRUD is durable, ordered, and exposed through chat state", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    chat = create_chat!(actor)
    generating = create_generating_message!(chat, actor)

    before_state =
      conn
      |> get(~p"/api/bff/chat-state/#{chat.id}")
      |> json_response(200)

    create_conn =
      post(conn, ~p"/api/bff/chat-generation/#{chat.id}/queue", %{
        "content" => "Send this next"
      })

    created = json_response(create_conn, 201)["queued_message"]
    assert created["kind"] == "follow_up"
    assert created["status"] == "pending"
    assert created["anchor_message_id"] == generating.id

    assert [%{"kind" => "text", "content_text" => "Send this next", "sequence" => 1}] =
             created["contents"]

    state =
      conn
      |> get(~p"/api/bff/chat-state/#{chat.id}")
      |> json_response(200)

    assert state["idle_revision"] != before_state["idle_revision"]
    assert [queued_payload] = state["queued_messages"]
    assert queued_payload["id"] == created["id"]

    update_conn =
      patch(conn, ~p"/api/bff/chat-queued-messages/#{created["id"]}", %{
        "content" => "Edited next message"
      })

    updated = json_response(update_conn, 200)["queued_message"]

    assert [%{"kind" => "text", "content_text" => "Edited next message"}] =
             updated["contents"]

    delete_conn = delete(conn, ~p"/api/bff/chat-queued-messages/#{created["id"]}")
    canceled = json_response(delete_conn, 200)["queued_message"]
    assert canceled["status"] == "canceled"
    assert canceled["contents"] == []

    final_state =
      conn
      |> get(~p"/api/bff/chat-state/#{chat.id}")
      |> json_response(200)

    assert final_state["queued_messages"] == []
  end

  test "queue mutation rejects another user", %{conn: conn} do
    %{user: owner, password: owner_password} = user_fixture()
    %{user: outsider, password: outsider_password} = user_fixture()
    owner_conn = sign_in_conn(conn, owner.username, owner_password)
    chat = create_chat!(owner)
    _generating = create_generating_message!(chat, owner)

    queued_message =
      owner_conn
      |> post(~p"/api/bff/chat-generation/#{chat.id}/queue", %{"content" => "Private"})
      |> json_response(201)
      |> Map.fetch!("queued_message")

    outsider_conn =
      build_conn()
      |> sign_in_conn(outsider.username, outsider_password)
      |> patch(~p"/api/bff/chat-queued-messages/#{queued_message["id"]}", %{
        "content" => "Changed"
      })

    assert outsider_conn.status in [403, 404]
  end

  test "queue rejects an empty payload", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    chat = create_chat!(actor)
    _generating = create_generating_message!(chat, actor)

    conn = post(conn, ~p"/api/bff/chat-generation/#{chat.id}/queue", %{"content" => ""})

    assert %{"code" => "empty_message"} = json_response(conn, 422)
  end

  test "terminal queue mutations return already_dispatched conflicts", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    chat = create_chat!(actor)
    _generating = create_generating_message!(chat, actor)

    queued_message =
      conn
      |> post(~p"/api/bff/chat-generation/#{chat.id}/queue", %{"content" => "Queued"})
      |> json_response(201)
      |> Map.fetch!("queued_message")

    assert {:ok, persisted} = QueuedMessages.get(queued_message["id"], actor)
    assert {:ok, _delivered} = QueuedMessages.mark_delivered(persisted, %{}, actor)

    patch_conn =
      patch(conn, ~p"/api/bff/chat-queued-messages/#{queued_message["id"]}", %{
        "content" => "Too late"
      })

    assert %{"code" => "already_dispatched"} = json_response(patch_conn, 409)

    delete_conn = delete(conn, ~p"/api/bff/chat-queued-messages/#{queued_message["id"]}")
    assert %{"code" => "already_dispatched"} = json_response(delete_conn, 409)
  end

  defp create_chat!(actor) do
    Chat
    |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_generating_message!(chat, actor) do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

    ChatMessage
    |> Ash.Changeset.for_create(
      :create_generating_assistant,
      %{chat_id: chat.id, parent_id: user_message.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
