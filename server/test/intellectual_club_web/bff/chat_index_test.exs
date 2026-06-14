defmodule IntellectualClubWeb.Bff.ChatIndexTest do
  @moduledoc """
  Chat list endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads

  test "GET /api/bff/chats returns first_message_preview from the first message", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, first} =
      Threads.add_message_to_end(chat, :user, "First line\nSecond line", actor: actor)

    {:ok, _second} =
      Threads.add_message(chat, :assistant, "Last message", actor: actor, parent_id: first.id)

    conn = get(conn, ~p"/api/bff/chats", %{"preview_len" => "10"})
    payload = json_response(conn, 200)

    chat_payload =
      payload
      |> Map.get("chats", [])
      |> Enum.find(fn item -> item["id"] == chat.id end)

    assert is_map(chat_payload)
    assert chat_payload["first_message_preview"] == "First line..."
    assert chat_payload["first_message_role"] == "user"
    assert chat_payload["message_count"] == 2

    assert payload["page"]["number"] == 1
    assert payload["page"]["per_page"] == 20
    assert payload["page"]["has_next"] == false
  end

  test "GET /api/bff/chats uses the first message from active branch root", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, _older_root} =
      Threads.add_message(chat, :assistant, "Older root", actor: actor, parent_id: nil)

    {:ok, _active_root} =
      Threads.add_message(chat, :assistant, "Active branch root", actor: actor, parent_id: nil)

    conn = get(conn, ~p"/api/bff/chats", %{"preview_len" => "30"})
    payload = json_response(conn, 200)

    chat_payload =
      payload
      |> Map.get("chats", [])
      |> Enum.find(fn item -> item["id"] == chat.id end)

    assert is_map(chat_payload)
    assert chat_payload["first_message_preview"] == "Active branch root"
    assert chat_payload["first_message_role"] == "assistant"
    assert chat_payload["message_count"] == 1
  end

  test "GET /api/bff/chats returns active_generation_message_id for generating chats", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn = get(conn, ~p"/api/bff/chats")
    payload = json_response(conn, 200)

    chat_payload =
      payload
      |> Map.get("chats", [])
      |> Enum.find(fn item -> item["id"] == chat.id end)

    assert is_map(chat_payload)
    assert chat_payload["active_generation_message_id"] == generating_message.id
    assert chat_payload["message_count"] == 2
  end

  test "GET /api/bff/chats paginates by page and per_page", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat_a =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    chat_b =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    chat_c =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    conn_page_1 = get(conn, ~p"/api/bff/chats", %{"page" => "1", "per_page" => "2"})
    payload_page_1 = json_response(conn_page_1, 200)

    ids_page_1 =
      payload_page_1
      |> Map.get("chats", [])
      |> Enum.map(& &1["id"])

    assert ids_page_1 == [chat_c.id, chat_b.id]
    assert payload_page_1["page"]["number"] == 1
    assert payload_page_1["page"]["per_page"] == 2
    assert payload_page_1["page"]["total"] == 3
    assert payload_page_1["page"]["has_next"] == true

    conn_page_2 = get(conn, ~p"/api/bff/chats", %{"page" => "2", "per_page" => "2"})
    payload_page_2 = json_response(conn_page_2, 200)

    ids_page_2 =
      payload_page_2
      |> Map.get("chats", [])
      |> Enum.map(& &1["id"])

    assert ids_page_2 == [chat_a.id]
    assert payload_page_2["page"]["number"] == 2
    assert payload_page_2["page"]["per_page"] == 2
    assert payload_page_2["page"]["total"] == 3
    assert payload_page_2["page"]["has_next"] == false
  end

  test "GET /api/bff/chats keeps message activity order after chat metadata changes", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    older_chat = create_chat!(actor, "Older activity")
    {:ok, _older_message} = Threads.add_message_to_end(older_chat, :user, "Older", actor: actor)

    Process.sleep(20)

    newer_chat = create_chat!(actor, "Newer activity")
    {:ok, _newer_message} = Threads.add_message_to_end(newer_chat, :user, "Newer", actor: actor)

    Process.sleep(20)

    conn
    |> patch(~p"/api/bff/chats/#{older_chat.id}", %{"note" => "Renamed older chat"})
    |> json_response(200)

    payload =
      conn
      |> get(~p"/api/bff/chats")
      |> json_response(200)

    idle_payload =
      conn
      |> get(~p"/api/bff/chats/idle-state")
      |> json_response(200)

    assert chat_ids(payload) == [newer_chat.id, older_chat.id]
    assert is_binary(idle_payload["revision"])
  end

  test "GET /api/bff/chats sorts empty chats by creation after chat metadata changes", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    older_chat = create_chat!(actor, "Older empty")

    Process.sleep(20)

    newer_chat = create_chat!(actor, "Newer empty")

    Process.sleep(20)

    conn
    |> patch(~p"/api/bff/chats/#{older_chat.id}", %{"note" => "Renamed older empty"})
    |> json_response(200)

    payload =
      conn
      |> get(~p"/api/bff/chats")
      |> json_response(200)

    newer_payload = chat_payload(payload, newer_chat.id)

    assert is_map(newer_payload)
    assert chat_ids(payload) == [newer_chat.id, older_chat.id]
    assert newer_payload["last_activity_at"] == newer_payload["created_at"]
    assert payload["stats"]["no_bot_last_activity_at"] == newer_payload["last_activity_at"]
  end

  test "GET /api/bff/chats sorts by active branch leaf instead of newer inactive messages", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    branched_chat = create_chat!(actor, "Branched inactive")
    {:ok, root} = Threads.add_message_to_end(branched_chat, :user, "Root", actor: actor)

    {:ok, active_leaf} =
      Threads.add_message(branched_chat, :assistant, "Active", actor: actor, parent_id: root.id)

    Process.sleep(20)

    newer_active_chat = create_chat!(actor, "Newer active")

    {:ok, _newer_active_message} =
      Threads.add_message_to_end(newer_active_chat, :user, "Newer active", actor: actor)

    Process.sleep(20)

    {:ok, _inactive_leaf} =
      Threads.add_message(branched_chat, :assistant, "Inactive newer",
        actor: actor,
        parent_id: root.id
      )

    {:ok, _branch_meta} = Threads.activate_branch(branched_chat, active_leaf.id, actor)

    payload =
      conn
      |> get(~p"/api/bff/chats")
      |> json_response(200)

    branched_payload = chat_payload(payload, branched_chat.id)

    assert is_map(branched_payload)
    assert chat_ids(payload) == [newer_active_chat.id, branched_chat.id]
    assert branched_payload["message_count"] == 2
  end

  test "GET /api/bff/chats returns sidebar stats independent from pagination and filter", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot_a = create_bot!(actor, "Bot A")
    bot_b = create_bot!(actor, "Bot B")

    chat_a =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", bot_id: bot_a.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _chat_b1 =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", bot_id: bot_b.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _chat_b2 =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", bot_id: bot_b.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _chat_without_bot =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    conn =
      get(conn, ~p"/api/bff/chats", %{
        "page" => "1",
        "per_page" => "1",
        "bot" => Integer.to_string(bot_a.id)
      })

    payload = json_response(conn, 200)

    assert payload["page"]["number"] == 1
    assert payload["page"]["per_page"] == 1
    assert payload["page"]["total"] == 1
    assert payload["page"]["has_next"] == false

    assert Enum.map(payload["chats"], & &1["id"]) == [chat_a.id]

    assert payload["stats"]["total_chats"] == 4
    assert payload["stats"]["no_bot_chat_count"] == 1
    assert is_binary(payload["stats"]["no_bot_last_activity_at"])

    assert Enum.sort_by(payload["stats"]["bots"], & &1["bot_id"]) == [
             %{"bot_id" => bot_a.id, "bot_name" => "Bot A", "chat_count" => 1},
             %{"bot_id" => bot_b.id, "bot_name" => "Bot B", "chat_count" => 2}
           ]
  end

  defp chat_ids(payload) do
    payload
    |> Map.get("chats", [])
    |> Enum.map(& &1["id"])
  end

  defp chat_payload(payload, chat_id) do
    payload
    |> Map.get("chats", [])
    |> Enum.find(fn item -> item["id"] == chat_id end)
  end

  defp create_chat!(actor, _title, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{note: ""}, attrs),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_bot!(actor, name) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        max_tool_rounds: 20,
        context_soft_limit_percent: 80,
        history_mode: :chat
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
