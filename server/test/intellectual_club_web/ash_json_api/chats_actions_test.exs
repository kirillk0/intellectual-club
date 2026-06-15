defmodule IntellectualClubWeb.AshJsonApi.ChatsActionsTest do
  @moduledoc """
  Regression tests for chat data actions exposed through Ash JSON:API.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.{Chat, ChatKnowledgeBlock, ChatMessage, Previews, Threads}
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationTag, LlmProvider}
  alias IntellectualClub.Tools.{ChatToolBinding, ToolInstance}

  require Ash.Query

  defp json_api_post(conn, path, attributes) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, %{
      "data" => %{
        "type" => type_for_path(path),
        "attributes" => attributes
      }
    })
  end

  defp json_api_patch(conn, path, attributes) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, %{
      "data" => %{
        "type" => type_for_path(path),
        "attributes" => attributes
      }
    })
  end

  test "POST /api/ash/chats applies default configuration and preserves explicit null", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_bot!(actor, "Assistant")
    provider = create_provider!(actor, "Provider")
    old_config = create_configuration!(actor, provider, "model-old")
    latest_config = create_configuration!(actor, provider, "model-new")

    create_chat!(actor, bot_id: bot.id, llm_configuration_id: old_config.id)
    create_chat!(actor, bot_id: bot.id, llm_configuration_id: latest_config.id)

    default_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats", %{"bot_id" => bot.id})
      |> json_response(201)

    default_chat = response_chat!(default_response, actor)
    assert default_chat.llm_configuration_id == latest_config.id

    null_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats", %{
        "bot_id" => bot.id,
        "llm_configuration_id" => nil
      })
      |> json_response(201)

    null_chat = response_chat!(null_response, actor)
    assert null_chat.llm_configuration_id == nil
  end

  test "POST /api/ash/chats uses bot default before compatible fallback", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    compatible_tag = create_configuration_tag!(actor, "Compatible")
    other_tag = create_configuration_tag!(actor, "Other")
    provider = create_provider!(actor, "Provider")

    _fallback_config =
      create_configuration!(actor, provider, "compatible-model", compatible_tag.id)

    default_config = create_configuration!(actor, provider, "default-model", other_tag.id)

    bot =
      create_bot!(actor, "Default bot",
        default_llm_configuration_id: default_config.id,
        compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: compatible_tag.id}]
      )

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats", %{"bot_id" => bot.id})
      |> json_response(201)

    chat = response_chat!(response, actor)
    assert chat.llm_configuration_id == default_config.id
  end

  test "PATCH /api/ash/chats/:id adjusts incompatible configuration when bot changes", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "Provider")
    old_tag = create_configuration_tag!(actor, "Old")
    new_tag = create_configuration_tag!(actor, "New")
    old_config = create_configuration!(actor, provider, "old-model", old_tag.id)
    new_config = create_configuration!(actor, provider, "new-model", new_tag.id)

    old_bot =
      create_bot!(actor, "Old bot",
        compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: old_tag.id}]
      )

    new_bot =
      create_bot!(actor, "New bot",
        compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: new_tag.id}]
      )

    create_chat!(actor, bot_id: new_bot.id, llm_configuration_id: new_config.id)
    chat = create_chat!(actor, bot_id: old_bot.id, llm_configuration_id: old_config.id)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_patch("/api/ash/chats/#{chat.id}", %{"bot_id" => new_bot.id})
      |> json_response(200)

    patched_chat = response_chat!(response, actor)
    assert patched_chat.bot_id == new_bot.id
    assert patched_chat.llm_configuration_id == new_config.id
  end

  test "POST /api/ash/chats/:id/copy copies chat bindings and rejects inaccessible source", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    %{user: other, password: other_password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor)
    block = create_knowledge_block!(actor)
    tool = create_tool_instance!(actor)
    create_chat_block_binding!(actor, source, block)
    create_chat_tool_binding!(actor, source, tool)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats/#{source.id}/copy", %{})
      |> json_response(201)

    target_id = response |> get_in(["data", "id"]) |> String.to_integer()

    assert [{block.id, false, 7}] ==
             chat_block_bindings!(target_id, actor)
             |> Enum.map(&{&1.knowledge_block_id, &1.enabled, &1.sequence})

    assert [{tool.id, true, 3}] ==
             chat_tool_bindings!(target_id, actor)
             |> Enum.map(&{&1.tool_instance_id, &1.enabled, &1.sequence})

    inaccessible_conn =
      build_conn()
      |> sign_in_conn(other.username, other_password)
      |> json_api_post("/api/ash/chats/#{source.id}/copy", %{})

    assert inaccessible_conn.status in [400, 403, 404, 422]
  end

  test "POST /api/ash/chats/:id/continue copies the active branch", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor)

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)
    {:ok, active} = Threads.add_message_to_end(source, :assistant, "Active", actor: actor)

    {:ok, _inactive} =
      Threads.add_message(source, :assistant, "Inactive", actor: actor, parent_id: root.id)

    {:ok, _meta} = Threads.activate_branch(source.id, active.id, actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats/#{source.id}/continue", %{})
      |> json_response(201)

    target_id = response |> get_in(["data", "id"]) |> String.to_integer()

    assert messages_for_chat!(target_id, actor) |> Enum.map(&message_text/1) == [
             "Root",
             "Active"
           ]
  end

  test "POST /api/ash/chats/:id/branch handles assistant and user replacement branches", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor)

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)
    {:ok, assistant} = Threads.add_message_to_end(source, :assistant, "Answer", actor: actor)
    {:ok, selected_user} = Threads.add_message_to_end(source, :user, "Original", actor: actor)
    {:ok, tail} = Threads.add_message_to_end(source, :assistant, "Tail", actor: actor)

    {:ok, inactive} =
      Threads.add_message(source, :assistant, "Inactive", actor: actor, parent_id: root.id)

    {:ok, _meta} = Threads.activate_branch(source.id, tail.id, actor)

    assistant_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats/#{source.id}/branch", %{"message_id" => assistant.id})
      |> json_response(201)

    assistant_target_id = assistant_response |> get_in(["data", "id"]) |> String.to_integer()
    assert messages_for_chat!(assistant_target_id, actor) |> Enum.map(&message_text/1) == ["Root"]

    user_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats/#{source.id}/branch", %{
        "message_id" => selected_user.id,
        "replacement_contents" => [%{"kind" => "text", "content_text" => "Replacement"}]
      })
      |> json_response(201)

    user_target_id = user_response |> get_in(["data", "id"]) |> String.to_integer()

    assert messages_for_chat!(user_target_id, actor) |> Enum.map(&message_text/1) == [
             "Root",
             "Answer",
             "Replacement"
           ]

    rejected =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats/#{source.id}/branch", %{"message_id" => inactive.id})

    assert rejected.status in [400, 422]
  end

  test "PATCH /api/ash/chats/:id/switch-branch and activate-branch change active leaf", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    chat = create_chat!(actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

    {:ok, first} =
      Threads.add_message(chat, :assistant, "First",
        actor: actor,
        parent_id: root.id
      )

    {:ok, second} =
      Threads.add_message(chat, :assistant, "Second",
        actor: actor,
        parent_id: root.id
      )

    {:ok, second_leaf} =
      Threads.add_message(chat, :user, "Second child",
        actor: actor,
        parent_id: second.id
      )

    {:ok, _meta} = Threads.activate_branch(chat.id, first.id, actor)

    conn
    |> recycle()
    |> sign_in_conn(actor.username, password)
    |> json_api_patch("/api/ash/chats/#{chat.id}/switch-branch", %{
      "message_id" => first.id,
      "target_id" => second.id
    })
    |> json_response(200)

    assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == second_leaf.id

    conn
    |> recycle()
    |> sign_in_conn(actor.username, password)
    |> json_api_patch("/api/ash/chats/#{chat.id}/activate-branch", %{"message_id" => first.id})
    |> json_response(200)

    assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == first.id
  end

  test "POST /api/ash/chat-messages/add-user creates content-bearing user messages", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    chat = create_chat!(actor)
    {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chat-messages/add-user", %{
        "chat_id" => chat.id,
        "parent_id" => root.id,
        "use_active_leaf_parent" => false,
        "contents" => [%{"kind" => "text", "content_text" => "Follow-up"}]
      })
      |> json_response(201)

    message_id = response |> get_in(["data", "id"]) |> String.to_integer()

    message =
      Ash.get!(ChatMessage, message_id, actor: actor)
      |> Ash.load!([steps: [items: [:contents]]], actor: actor)

    assert message.role == :user
    assert message.parent_id == root.id
    assert message_text(message) == "Follow-up"
  end

  defp type_for_path(path) do
    if String.contains?(path, "/chat-messages/") do
      "chat-messages"
    else
      "chats"
    end
  end

  defp response_chat!(response, actor) do
    response
    |> get_in(["data", "id"])
    |> String.to_integer()
    |> then(&Ash.get!(Chat, &1, actor: actor))
  end

  defp create_chat!(actor, attrs \\ []) do
    attrs = Map.new(attrs)

    Chat
    |> Ash.Changeset.for_create(:create_empty, Map.merge(%{note: ""}, attrs), actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_bot!(actor, name, attrs \\ []) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          name: name,
          first_messages: [],
          max_tool_rounds: 20,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        Map.new(attrs)
      ),
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

  defp create_configuration!(actor, provider, model_name, tag_id \\ nil) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: model_name,
        note: "cfg",
        parameters: %{},
        enabled: true,
        timeout_seconds: 300,
        tag_bindings: if(is_integer(tag_id), do: [%{llm_configuration_tag_id: tag_id}], else: nil)
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration_tag!(actor, name) do
    LlmConfigurationTag
    |> Ash.Changeset.for_create(:create, %{name: name}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_knowledge_block!(actor) do
    KnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Chat block", version: "v1", content: "Knowledge"},
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
      %{chat_id: chat.id, knowledge_block_id: block.id, enabled: false, sequence: 7},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_chat_tool_binding!(actor, chat, tool) do
    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: tool.id, enabled: true, sequence: 3},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp chat_block_bindings!(chat_id, actor) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: actor)
  end

  defp chat_tool_bindings!(chat_id, actor) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: actor)
  end

  defp messages_for_chat!(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(steps: [items: [:contents]])
    |> Ash.read!(actor: actor)
  end

  defp message_text(%ChatMessage{} = message) do
    Previews.message_preview_text(message)
  end
end
