defmodule IntellectualClubWeb.Bff.ChatIdleStateTest do
  @moduledoc """
  Idle polling endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads

  test "GET /api/bff/chats/idle-state returns a revision and then 204 for unchanged state", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    _chat = create_chat!(actor, "Idle list")

    payload =
      conn
      |> get(~p"/api/bff/chats/idle-state")
      |> json_response(200)

    assert is_binary(payload["revision"])
    assert payload["active_generation_message_id"] == nil

    conn = get(conn, ~p"/api/bff/chats/idle-state?revision=#{payload["revision"]}")
    assert response(conn, 204) == ""
  end

  test "GET /api/bff/chats/idle-state changes after generation starts on the page", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Idle list generation")

    initial_payload =
      conn
      |> get(~p"/api/bff/chats/idle-state")
      |> json_response(200)

    generating_message = create_generating_message!(chat, actor)

    changed_payload =
      conn
      |> get(~p"/api/bff/chats/idle-state?revision=#{initial_payload["revision"]}")
      |> json_response(200)

    assert changed_payload["revision"] != initial_payload["revision"]
    assert changed_payload["active_generation_message_id"] == generating_message.id
  end

  test "GET /api/bff/chats/:id/idle-state returns 204 for unchanged state and changes after generation starts",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Idle chat")

    initial_payload =
      conn
      |> get(~p"/api/bff/chats/#{chat.id}/idle-state")
      |> json_response(200)

    assert is_binary(initial_payload["revision"])
    assert initial_payload["active_generation_message_id"] == nil

    unchanged_conn =
      get(conn, ~p"/api/bff/chats/#{chat.id}/idle-state?revision=#{initial_payload["revision"]}")

    assert response(unchanged_conn, 204) == ""

    generating_message = create_generating_message!(chat, actor)

    changed_payload =
      conn
      |> get(~p"/api/bff/chats/#{chat.id}/idle-state?revision=#{initial_payload["revision"]}")
      |> json_response(200)

    assert changed_payload["revision"] != initial_payload["revision"]
    assert changed_payload["active_generation_message_id"] == generating_message.id
  end

  test "GET /api/bff/chats/:id/idle-state matches state access errors", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(owner, "Private idle chat")

    state_conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
    idle_conn = get(conn, ~p"/api/bff/chats/#{chat.id}/idle-state")

    assert idle_conn.status == state_conn.status

    assert json_response(idle_conn, idle_conn.status) ==
             json_response(state_conn, state_conn.status)
  end

  defp create_chat!(actor, title) do
    Chat
    |> Ash.Changeset.for_create(:create, %{title: title, note: ""}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_generating_message!(chat, actor) do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    ChatMessage
    |> Ash.Changeset.for_create(
      :create_generating_assistant,
      %{chat_id: chat.id, parent_id: user_message.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
