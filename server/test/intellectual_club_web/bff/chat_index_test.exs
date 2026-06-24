defmodule IntellectualClubWeb.Bff.ChatIndexTest do
  @moduledoc """
  Chat list endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance

  test "GET /api/bff/chat-list returns first_message_preview from the first message", %{
    conn: conn
  } do
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

    conn = get(conn, ~p"/api/bff/chat-list", %{"preview_len" => "10"})
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

  test "GET /api/bff/chat-list returns loaded configuration labels", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "List Provider")
    configuration = create_configuration!(actor, provider, "list-model", "primary")
    chat = create_chat!(actor, "Configured", %{llm_configuration_id: configuration.id})

    payload =
      conn
      |> get(~p"/api/bff/chat-list")
      |> json_response(200)

    chat_payload = chat_payload(payload, chat.id)

    assert is_map(chat_payload)
    assert chat_payload["llm_configuration_id"] == configuration.id
    assert chat_payload["llm_configuration_label"] == "list-model (primary)"
  end

  test "GET /api/bff/chat-list returns chat block and tool counts", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat_with_bindings = create_chat!(actor, "With bindings")
    empty_chat = create_chat!(actor, "Without bindings")

    first_block = create_knowledge_block!(actor, "List Block A")
    second_block = create_knowledge_block!(actor, "List Block B")
    tool = create_tool_instance!(actor)

    create_chat_block_binding!(actor, chat_with_bindings, first_block)
    create_chat_block_binding!(actor, chat_with_bindings, second_block)
    create_chat_tool_binding!(actor, chat_with_bindings, tool)

    payload =
      conn
      |> get(~p"/api/bff/chat-list")
      |> json_response(200)

    chat_payload = chat_payload(payload, chat_with_bindings.id)
    empty_payload = chat_payload(payload, empty_chat.id)

    assert is_map(chat_payload)
    assert chat_payload["blocks_count"] == 2
    assert chat_payload["tools_count"] == 1

    assert is_map(empty_payload)
    assert empty_payload["blocks_count"] == 0
    assert empty_payload["tools_count"] == 0
  end

  test "GET /api/bff/chat-list uses the first message from active branch root", %{conn: conn} do
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

    conn = get(conn, ~p"/api/bff/chat-list", %{"preview_len" => "30"})
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

  test "GET /api/bff/chat-list returns active_generation_message_id for generating chats", %{
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

    conn = get(conn, ~p"/api/bff/chat-list")
    payload = json_response(conn, 200)

    chat_payload =
      payload
      |> Map.get("chats", [])
      |> Enum.find(fn item -> item["id"] == chat.id end)

    assert is_map(chat_payload)
    assert chat_payload["active_generation_message_id"] == generating_message.id
    assert chat_payload["message_count"] == 2
  end

  test "GET /api/bff/chat-list paginates by page and per_page", %{conn: conn} do
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

    conn_page_1 = get(conn, ~p"/api/bff/chat-list", %{"page" => "1", "per_page" => "2"})
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

    conn_page_2 = get(conn, ~p"/api/bff/chat-list", %{"page" => "2", "per_page" => "2"})
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

  test "GET /api/bff/chat-list keeps message activity order after chat metadata changes", %{
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
    |> json_api_patch("/api/ash/chats/#{older_chat.id}", %{"note" => "Renamed older chat"})
    |> json_response(200)

    payload =
      conn
      |> get(~p"/api/bff/chat-list")
      |> json_response(200)

    idle_payload =
      conn
      |> get(~p"/api/bff/chat-list/idle-state")
      |> json_response(200)

    assert chat_ids(payload) == [newer_chat.id, older_chat.id]
    assert is_binary(idle_payload["revision"])
  end

  test "GET /api/bff/chat-list sorts empty chats by creation after chat metadata changes", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    older_chat = create_chat!(actor, "Older empty")

    Process.sleep(20)

    newer_chat = create_chat!(actor, "Newer empty")

    Process.sleep(20)

    conn
    |> json_api_patch("/api/ash/chats/#{older_chat.id}", %{"note" => "Renamed older empty"})
    |> json_response(200)

    payload =
      conn
      |> get(~p"/api/bff/chat-list")
      |> json_response(200)

    newer_payload = chat_payload(payload, newer_chat.id)

    assert is_map(newer_payload)
    assert chat_ids(payload) == [newer_chat.id, older_chat.id]
    assert newer_payload["last_activity_at"] == newer_payload["created_at"]
    assert payload["stats"]["no_bot_last_activity_at"] == newer_payload["last_activity_at"]
  end

  test "GET /api/bff/chat-list sorts by active branch leaf instead of newer inactive messages", %{
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
      |> get(~p"/api/bff/chat-list")
      |> json_response(200)

    branched_payload = chat_payload(payload, branched_chat.id)

    assert is_map(branched_payload)
    assert chat_ids(payload) == [newer_active_chat.id, branched_chat.id]
    assert branched_payload["message_count"] == 2
  end

  test "GET /api/bff/chat-list returns sidebar stats independent from pagination and filter", %{
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
      get(conn, ~p"/api/bff/chat-list", %{
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

  defp json_api_patch(conn, path, attributes) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, %{
      "data" => %{
        "type" => "chats",
        "attributes" => attributes
      }
    })
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

  defp create_provider!(actor, name) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        type: :openrouter_chat_completion,
        auth_method: :api_key,
        base_url: "https://openrouter.ai/api/v1",
        api_key: "test-key"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration!(actor, provider, model_name, note) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: model_name,
        note: note,
        parameters: %{},
        enabled: true,
        timeout_seconds: 300
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_knowledge_block!(actor, name) do
    KnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, version: "v1", content: "Knowledge"},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_tool_instance!(actor) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-agent-management",
        name: "Agent management",
        description: "",
        alias: "agent_management",
        config: %{},
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_chat_block_binding!(actor, chat, block) do
    ChatKnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, knowledge_block_id: block.id, enabled: true, sequence: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_chat_tool_binding!(actor, chat, tool) do
    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: tool.id, enabled: true, sequence: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
