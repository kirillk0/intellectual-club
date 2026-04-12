defmodule IntellectualClubWeb.Bff.ChatSearchTest do
  @moduledoc """
  Search endpoint tests for the chat SPA BFF.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Db

  test "GET /api/bff/chats/:id/search splits active/inactive hits", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{title: "Search chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

    {:ok, active_msg} =
      Threads.add_message(chat, :assistant, "Find me active", actor: actor, parent_id: root.id)

    {:ok, inactive_msg} =
      Threads.add_message(chat, :assistant, "Find me inactive", actor: actor, parent_id: root.id)

    {:ok, _branch} = Threads.activate_branch(chat.id, active_msg.id, actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/search", %{"q" => "Find"})
    payload = json_response(conn, 200)

    assert length(payload["active"] || []) == 1
    assert length(payload["inactive"] || []) == 1

    assert List.first(payload["active"])["id"] == active_msg.id
    assert List.first(payload["inactive"])["id"] == inactive_msg.id

    assert is_binary(List.first(payload["active"])["snippet"])
    assert is_binary(List.first(payload["inactive"])["snippet"])
    assert is_binary(List.first(payload["active"])["finished_at"])
    assert is_binary(List.first(payload["inactive"])["finished_at"])
  end

  test "GET /api/bff/chats/:id/search returns empty results for empty term", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Empty search chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/search", %{"q" => ""})
    payload = json_response(conn, 200)

    assert payload["active"] == []
    assert payload["inactive"] == []
  end

  test "GET /api/bff/chats/:id/search uses case-insensitive unicode matching", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Unicode prefix chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, message} = Threads.add_message_to_end(chat, :user, "Привет мир", actor: actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/search", %{"q" => "ПРИВ"})
    payload = json_response(conn, 200)

    assert Enum.map(payload["active"] || [], & &1["id"]) == [message.id]
    assert payload["inactive"] == []
  end

  test "GET /api/bff/chats/:id/search uses adapter-specific substring semantics", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Unicode infix chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _message} = Threads.add_message_to_end(chat, :user, "Привет мир", actor: actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/search", %{"q" => "рив"})
    payload = json_response(conn, 200)

    if Db.sqlite?() do
      assert payload["active"] == []
    else
      assert Enum.map(payload["active"] || [], & &1["content"]) == ["Привет мир"]
    end

    assert payload["inactive"] == []
  end

  test "GET /api/bff/chats/:id/search uses adapter-specific multi-token semantics", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "And search chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, matching} = Threads.add_message_to_end(chat, :user, "alpha beta", actor: actor)
    {:ok, _other} = Threads.add_message_to_end(chat, :assistant, "alpha only", actor: actor)

    if Db.sqlite?() do
      conn = get(conn, ~p"/api/bff/chats/#{chat.id}/search", %{"q" => "beta alpha"})
      payload = json_response(conn, 200)

      assert Enum.map(payload["active"] || [], & &1["id"]) == [matching.id]
      assert payload["inactive"] == []
    else
      exact_order_conn = get(conn, ~p"/api/bff/chats/#{chat.id}/search", %{"q" => "alpha beta"})
      exact_order_payload = json_response(exact_order_conn, 200)

      assert Enum.map(exact_order_payload["active"] || [], & &1["id"]) == [matching.id]
      assert exact_order_payload["inactive"] == []

      reversed_conn = get(conn, ~p"/api/bff/chats/#{chat.id}/search", %{"q" => "beta alpha"})
      reversed_payload = json_response(reversed_conn, 200)

      assert reversed_payload["active"] == []
      assert reversed_payload["inactive"] == []
    end
  end

  test "GET /api/bff/chats/search returns meta/active/inactive match types", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    meta_bot = create_bot!(actor, "Arsen Bot")

    chat_meta =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Meta chat", note: "arsen note", bot_id: meta_bot.id, variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    active_bot = create_bot!(actor, "Other Bot")

    chat_active =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Active match chat", note: "", bot_id: active_bot.id, variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, active_msg} =
      Threads.add_message_to_end(chat_active, :user, "arsen active message", actor: actor)

    inactive_bot = create_bot!(actor, "Another Bot")

    chat_inactive =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Inactive match chat", note: "", bot_id: inactive_bot.id, variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat_inactive, :user, "root", actor: actor)

    {:ok, inactive_msg} =
      Threads.add_message(chat_inactive, :assistant, "arsen inactive message",
        actor: actor,
        parent_id: root.id
      )

    {:ok, _active_leaf} =
      Threads.add_message(chat_inactive, :assistant, "Other branch",
        actor: actor,
        parent_id: root.id
      )

    conn = get(conn, ~p"/api/bff/chats/search", %{"q" => "arsen"})
    payload = json_response(conn, 200)

    results = payload["chats"] || []
    assert Enum.map(results, & &1["match_type"]) == ["meta", "active_message", "inactive_message"]

    assert Enum.at(results, 0)["id"] == chat_meta.id
    assert Enum.at(results, 0)["message_count"] == 0

    assert Enum.at(results, 1)["id"] == chat_active.id
    assert Enum.at(results, 1)["message_id"] == active_msg.id
    assert Enum.at(results, 1)["message_count"] == 1

    assert Enum.at(results, 2)["id"] == chat_inactive.id
    assert Enum.at(results, 2)["message_id"] == inactive_msg.id
    assert Enum.at(results, 2)["message_count"] == 2
  end

  test "GET /api/bff/chats/search uses case-insensitive matching for message hits", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Global unicode chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, message} = Threads.add_message_to_end(chat, :user, "Привет мир", actor: actor)

    conn = get(conn, ~p"/api/bff/chats/search", %{"q" => "ПРИВ"})
    payload = json_response(conn, 200)
    results = payload["chats"] || []

    result = Enum.find(results, &(&1["id"] == chat.id))

    assert is_map(result)
    assert result["match_type"] == "active_message"
    assert result["message_id"] == message.id
    assert is_binary(result["snippet"])
  end

  test "GET /api/bff/chats/search handles large assistant traces", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Large trace chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: chat.id,
          role: :assistant,
          parent_id: root.id,
          status: :done,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: message.id,
          sequence: 1,
          status: :done,
          raw_request: %{},
          response_final: true
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    item_payloads =
      Enum.map(1..1001, fn sequence ->
        %{
          chat_message_step_id: step.id,
          sequence: sequence,
          type: :answer
        }
      end)

    %Ash.BulkResult{records: items} =
      Ash.bulk_create!(item_payloads, ChatMessageItem, :create,
        actor: actor,
        return_records?: true
      )

    content_payloads =
      items
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map(fn item ->
        %{
          chat_message_item_id: item.id,
          sequence: 1,
          kind: :text,
          content_text: "needle fragment #{item.sequence}"
        }
      end)

    _bulk_result =
      Ash.bulk_create!(content_payloads, ChatMessageContent, :create, actor: actor)

    conn = get(conn, ~p"/api/bff/chats/search", %{"q" => "needle"})
    payload = json_response(conn, 200)
    results = payload["chats"] || []

    result = Enum.find(results, &(&1["id"] == chat.id))

    assert is_map(result)
    assert result["match_type"] == "active_message"
    assert result["message_id"] == message.id
    assert is_binary(result["snippet"])
  end

  test "GET /api/bff/chats/search respects per_page as total result limit", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    Enum.each(1..12, fn idx ->
      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{title: "Paged chat #{idx}", note: "", variables: %{}},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, _message} =
        Threads.add_message_to_end(chat, :user, "paged needle #{idx}", actor: actor)
    end)

    conn = get(conn, ~p"/api/bff/chats/search", %{"q" => "needle", "per_page" => "5"})
    payload = json_response(conn, 200)
    results = payload["chats"] || []

    assert length(results) == 5
    assert Enum.all?(results, &(&1["match_type"] == "active_message"))
  end

  defp create_bot!(actor, name) when is_binary(name) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        variables: %{},
        max_tool_rounds: 20,
        context_soft_limit_percent: 80,
        history_mode: :chat
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
