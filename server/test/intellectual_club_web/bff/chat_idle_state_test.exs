defmodule IntellectualClubWeb.Bff.ChatIdleStateTest do
  @moduledoc """
  Idle polling endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  require Ash.Query

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads

  test "GET /api/bff/chat-list/idle-state returns a revision and then 204 for unchanged state", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    _chat = create_chat!(actor, "Idle list")

    payload =
      conn
      |> get(~p"/api/bff/chat-list/idle-state")
      |> json_response(200)

    assert is_binary(payload["revision"])
    assert payload["active_generation_message_id"] == nil

    conn = get(conn, ~p"/api/bff/chat-list/idle-state?revision=#{payload["revision"]}")
    assert response(conn, 204) == ""
  end

  test "GET /api/bff/chat-list/idle-state changes after generation starts on the page", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Idle list generation")

    initial_payload =
      conn
      |> get(~p"/api/bff/chat-list/idle-state")
      |> json_response(200)

    generating_message = create_generating_message!(chat, actor)

    changed_payload =
      conn
      |> get(~p"/api/bff/chat-list/idle-state?revision=#{initial_payload["revision"]}")
      |> json_response(200)

    assert changed_payload["revision"] != initial_payload["revision"]
    assert changed_payload["active_generation_message_id"] == generating_message.id
  end

  test "GET /api/bff/chat-state/:id/idle-state returns 204 for unchanged state and changes after generation starts",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Idle chat")

    initial_payload =
      conn
      |> get(~p"/api/bff/chat-state/#{chat.id}/idle-state")
      |> json_response(200)

    assert is_binary(initial_payload["revision"])
    assert initial_payload["active_generation_message_id"] == nil

    unchanged_conn =
      get(
        conn,
        ~p"/api/bff/chat-state/#{chat.id}/idle-state?revision=#{initial_payload["revision"]}"
      )

    assert response(unchanged_conn, 204) == ""

    generating_message = create_generating_message!(chat, actor)

    changed_payload =
      conn
      |> get(
        ~p"/api/bff/chat-state/#{chat.id}/idle-state?revision=#{initial_payload["revision"]}"
      )
      |> json_response(200)

    assert changed_payload["revision"] != initial_payload["revision"]
    assert changed_payload["active_generation_message_id"] == generating_message.id
  end

  test "GET /api/bff/chat-state/:id tracks generation state changes in fork children", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    parent = create_chat!(actor, "Parent chat")
    {:ok, parent_message} = Threads.add_message_to_end(parent, :user, "Delegate", actor: actor)

    initial_idle =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}/idle-state")
      |> json_response(200)

    child =
      create_chat!(actor, "Fork child", %{
        parent_chat_id: parent.id,
        parent_message_id: parent_message.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    {:ok, child_message} = Threads.add_message_to_end(child, :user, "Work", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: child.id, parent_id: child_message.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    generating_idle =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}/idle-state?revision=#{initial_idle["revision"]}")
      |> json_response(200)

    assert generating_idle["revision"] != initial_idle["revision"]

    generating_state =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}")
      |> json_response(200)

    generating_relation = child_relation(generating_state, parent_message.id, child.id)
    assert generating_relation["active_generation_message_id"] == generating_message.id
    assert generating_relation["last_message_status"] == "generating"
    assert generating_state["idle_revision"] == generating_idle["revision"]

    generating_message
    |> Ash.Changeset.for_update(
      :set_generation_state,
      %{status: :error, error_detail: "Provider failed"},
      actor: actor
    )
    |> Ash.update!(actor: actor)

    error_idle =
      conn
      |> get(
        ~p"/api/bff/chat-state/#{parent.id}/idle-state?revision=#{generating_idle["revision"]}"
      )
      |> json_response(200)

    assert error_idle["revision"] != generating_idle["revision"]

    error_state =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}")
      |> json_response(200)

    error_relation = child_relation(error_state, parent_message.id, child.id)
    assert error_relation["active_generation_message_id"] == nil
    assert error_relation["last_message_status"] == "error"
    assert error_state["idle_revision"] == error_idle["revision"]
  end

  test "idle revisions and relations follow a fork child through handoff", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    parent = create_chat!(actor, "Parent")
    {:ok, parent_message} = Threads.add_message_to_end(parent, :user, "Delegate", actor: actor)

    initial_idle =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}/idle-state")
      |> json_response(200)

    child =
      create_chat!(actor, "Fork child", %{
        parent_chat_id: parent.id,
        parent_message_id: parent_message.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    source_message = create_generating_message_with_step!(child, actor)

    continuation =
      create_chat!(actor, "Handoff child", %{
        parent_chat_id: child.id,
        parent_message_id: source_message.id,
        parent_relation_kind: :handoff,
        subagent: true
      })

    continuation_message = create_generating_message_with_step!(continuation, actor)
    persist_handoff_result!(source_message, continuation, continuation_message, actor)
    set_message_status!(source_message, :done, actor)

    active_idle =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}/idle-state?revision=#{initial_idle["revision"]}")
      |> json_response(200)

    active_state =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}")
      |> json_response(200)

    active_relation = child_relation(active_state, parent_message.id, child.id)
    assert active_relation["active_generation_message_id"] == continuation_message.id
    assert active_relation["last_message_status"] == "generating"
    assert active_state["idle_revision"] == active_idle["revision"]

    active_list_idle =
      conn
      |> get(~p"/api/bff/chat-list/idle-state")
      |> json_response(200)

    assert active_list_idle["active_generation_message_id"] == continuation_message.id

    set_message_status!(continuation_message, :canceled, actor)

    settled_idle =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}/idle-state?revision=#{active_idle["revision"]}")
      |> json_response(200)

    settled_state =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}")
      |> json_response(200)

    settled_relation = child_relation(settled_state, parent_message.id, child.id)
    assert settled_relation["active_generation_message_id"] == nil
    assert settled_relation["last_message_status"] == "canceled"
    assert settled_state["idle_revision"] == settled_idle["revision"]

    settled_list_idle =
      conn
      |> get(~p"/api/bff/chat-list/idle-state?revision=#{active_list_idle["revision"]}")
      |> json_response(200)

    assert settled_list_idle["revision"] != active_list_idle["revision"]
    assert settled_list_idle["active_generation_message_id"] == nil
  end

  test "GET /api/bff/chat-state/:id/idle-state matches state access errors", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(owner, "Private idle chat")

    state_conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}")
    idle_conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}/idle-state")

    assert idle_conn.status == state_conn.status

    assert json_response(idle_conn, idle_conn.status) ==
             json_response(state_conn, state_conn.status)
  end

  defp child_relation(payload, parent_message_id, child_id) do
    payload["relations"]["children_by_message_id"][Integer.to_string(parent_message_id)]
    |> Enum.find(&(&1["chat_id"] == child_id))
  end

  defp create_chat!(actor, _title, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :note, ""), actor: actor)
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

  defp create_generating_message_with_step!(chat, actor) do
    message = create_generating_message!(chat, actor)

    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_id: message.id, sequence: 1, status: :waiting_provider},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    message
  end

  defp set_message_status!(message, status, actor) do
    message
    |> Ash.Changeset.for_update(:set_generation_state, %{status: status}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp persist_handoff_result!(source_message, child_chat, child_message, actor) do
    step =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^source_message.id)
      |> Ash.Query.sort(sequence: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(actor: actor)

    call_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 1, type: :tool_call},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    result_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: 2,
          type: :tool_result,
          tool_call_item_id: call_item.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: result_item.id,
        sequence: 1,
        kind: :opaque,
        content_text: "",
        content_json: %{
          "raw" => %{
            "handoff" => %{
              "chat_id" => child_chat.id,
              "generation_message_id" => child_message.id
            }
          }
        }
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
