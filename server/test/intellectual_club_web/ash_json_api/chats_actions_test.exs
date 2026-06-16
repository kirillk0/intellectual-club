defmodule IntellectualClubWeb.AshJsonApi.ChatsActionsTest do
  @moduledoc """
  Regression tests for chat data actions exposed through Ash JSON:API.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}

  alias IntellectualClub.Chat.{
    Chat,
    ChatKnowledgeBlock,
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep,
    Previews,
    Threads
  }

  alias IntellectualClub.Db
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilePayload
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationTag, LlmProvider}
  alias IntellectualClub.Tools.{ChatToolBinding, ToolInstance}

  import Ecto.Query
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

  defp json_api_delete(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> delete(path)
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

  test "POST /api/ash/chats scopes default configuration history by bot and no-bot chats",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot_a = create_bot!(actor, "Bot A")
    bot_b = create_bot!(actor, "Bot B")
    provider = create_provider!(actor, "Provider")
    config_a = create_configuration!(actor, provider, "model-a")
    config_b = create_configuration!(actor, provider, "model-b")
    config_old_no_bot = create_configuration!(actor, provider, "model-old-no-bot")
    config_new_no_bot = create_configuration!(actor, provider, "model-new-no-bot")

    create_chat!(actor, bot_id: bot_a.id, llm_configuration_id: config_a.id)
    create_chat!(actor, bot_id: bot_b.id, llm_configuration_id: config_b.id)
    create_chat!(actor, llm_configuration_id: config_old_no_bot.id)
    create_chat!(actor, llm_configuration_id: config_new_no_bot.id)

    bot_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats", %{"bot_id" => bot_a.id})
      |> json_response(201)

    assert response_chat!(bot_response, actor).llm_configuration_id == config_a.id

    no_bot_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats", %{})
      |> json_response(201)

    no_bot_chat = response_chat!(no_bot_response, actor)
    assert no_bot_chat.bot_id == nil
    assert no_bot_chat.llm_configuration_id == config_new_no_bot.id
  end

  test "POST /api/ash/chats uses fallback ordering when chat history is unavailable", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    provider = create_provider!(actor, "Provider")
    config_b = create_configuration!(actor, provider, "model-b")
    config_a = create_configuration!(actor, provider, "model-a")

    first_available_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats", %{})
      |> json_response(201)

    first_available_chat = response_chat!(first_available_response, actor)
    assert first_available_chat.llm_configuration_id == config_a.id
    refute first_available_chat.llm_configuration_id == config_b.id

    %{user: bot_actor, password: bot_password} = user_fixture()
    bot_conn = build_conn() |> sign_in_conn(bot_actor.username, bot_password)
    bot_provider = create_provider!(bot_actor, "Bot provider")
    fallback_config = create_configuration!(bot_actor, bot_provider, "model-fallback")
    default_config = create_configuration!(bot_actor, bot_provider, "model-default")
    bot = create_bot!(bot_actor, "Default bot", default_llm_configuration_id: default_config.id)

    bot_default_response =
      bot_conn
      |> json_api_post("/api/ash/chats", %{"bot_id" => bot.id})
      |> json_response(201)

    bot_default_chat = response_chat!(bot_default_response, bot_actor)
    assert bot_default_chat.llm_configuration_id == default_config.id
    refute bot_default_chat.llm_configuration_id == fallback_config.id
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

  test "POST /api/ash/chats keeps advanced default configuration precedence", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    provider = create_provider!(actor, "Provider")
    default_config = create_configuration!(actor, provider, "model-default")
    latest_config = create_configuration!(actor, provider, "model-latest")
    bot = create_bot!(actor, "History bot", default_llm_configuration_id: default_config.id)
    create_chat!(actor, bot_id: bot.id, llm_configuration_id: latest_config.id)

    latest_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/chats", %{"bot_id" => bot.id})
      |> json_response(201)

    assert response_chat!(latest_response, actor).llm_configuration_id == latest_config.id

    %{user: compatible_actor, password: compatible_password} = user_fixture()
    compatible_conn = build_conn() |> sign_in_conn(compatible_actor.username, compatible_password)
    compatible_tag = create_configuration_tag!(compatible_actor, "Compatible")
    other_tag = create_configuration_tag!(compatible_actor, "Other")
    compatible_provider = create_provider!(compatible_actor, "Compatible provider")

    compatible_config =
      create_configuration!(
        compatible_actor,
        compatible_provider,
        "model-compatible",
        compatible_tag.id
      )

    incompatible_config =
      create_configuration!(
        compatible_actor,
        compatible_provider,
        "model-incompatible",
        other_tag.id
      )

    compatible_bot =
      create_bot!(compatible_actor, "Compatible bot",
        compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: compatible_tag.id}]
      )

    create_chat!(compatible_actor,
      bot_id: compatible_bot.id,
      llm_configuration_id: compatible_config.id
    )

    create_chat!(compatible_actor,
      bot_id: compatible_bot.id,
      llm_configuration_id: incompatible_config.id
    )

    compatible_response =
      compatible_conn
      |> json_api_post("/api/ash/chats", %{"bot_id" => compatible_bot.id})
      |> json_response(201)

    assert response_chat!(compatible_response, compatible_actor).llm_configuration_id ==
             compatible_config.id

    %{user: disabled_actor, password: disabled_password} = user_fixture()
    disabled_conn = build_conn() |> sign_in_conn(disabled_actor.username, disabled_password)
    disabled_compatible_tag = create_configuration_tag!(disabled_actor, "Compatible")
    disabled_other_tag = create_configuration_tag!(disabled_actor, "Other")
    disabled_provider = create_provider!(disabled_actor, "Disabled provider")

    _fallback_config =
      create_configuration!(
        disabled_actor,
        disabled_provider,
        "model-compatible",
        disabled_compatible_tag.id
      )

    disabled_default_config =
      create_configuration!(
        disabled_actor,
        disabled_provider,
        "model-disabled-default",
        disabled_other_tag.id,
        enabled: false
      )

    disabled_bot =
      create_bot!(disabled_actor, "Disabled default bot",
        default_llm_configuration_id: disabled_default_config.id,
        compatible_configuration_tag_bindings: [
          %{llm_configuration_tag_id: disabled_compatible_tag.id}
        ]
      )

    disabled_default_response =
      disabled_conn
      |> json_api_post("/api/ash/chats", %{"bot_id" => disabled_bot.id})
      |> json_response(201)

    assert response_chat!(disabled_default_response, disabled_actor).llm_configuration_id ==
             disabled_default_config.id

    %{user: no_bot_actor, password: no_bot_password} = user_fixture()
    no_bot_conn = build_conn() |> sign_in_conn(no_bot_actor.username, no_bot_password)
    no_bot_provider = create_provider!(no_bot_actor, "No bot provider")
    enabled_config = create_configuration!(no_bot_actor, no_bot_provider, "model-enabled")

    disabled_latest_config =
      create_configuration!(no_bot_actor, no_bot_provider, "model-disabled-latest", nil,
        enabled: false
      )

    create_chat!(no_bot_actor, llm_configuration_id: disabled_latest_config.id)

    no_bot_response =
      no_bot_conn
      |> json_api_post("/api/ash/chats", %{})
      |> json_response(201)

    assert response_chat!(no_bot_response, no_bot_actor).llm_configuration_id == enabled_config.id
  end

  test "POST /api/ash/chats matches shared bot compatible tags by name", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})
    conn = sign_in_conn(conn, recipient.username, password)

    owner_tag = create_configuration_tag!(owner, "Compatible")
    recipient_tag = create_configuration_tag!(recipient, "compatible")
    other_tag = create_configuration_tag!(recipient, "Other")

    bot =
      create_bot!(owner, "Shared compatible bot",
        compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: owner_tag.id}]
      )

    share_bot!(owner, bot, group)

    provider = create_provider!(recipient, "Recipient provider")

    compatible_config =
      create_configuration!(recipient, provider, "model-compatible", recipient_tag.id)

    _incompatible_config =
      create_configuration!(recipient, provider, "model-incompatible", other_tag.id)

    response =
      conn
      |> json_api_post("/api/ash/chats", %{"bot_id" => bot.id})
      |> json_response(201)

    chat = response_chat!(response, recipient)
    assert chat.bot_id == bot.id
    assert chat.llm_configuration_id == compatible_config.id
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

  test "PATCH /api/ash/chats/:id matches shared bot compatible tags by name", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})
    conn = sign_in_conn(conn, recipient.username, password)

    owner_tag = create_configuration_tag!(owner, "Compatible")
    recipient_tag = create_configuration_tag!(recipient, "compatible")
    other_tag = create_configuration_tag!(recipient, "Other")

    bot =
      create_bot!(owner, "Shared patch bot",
        compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: owner_tag.id}]
      )

    share_bot!(owner, bot, group)

    provider = create_provider!(recipient, "Recipient provider")

    compatible_config =
      create_configuration!(recipient, provider, "model-compatible", recipient_tag.id)

    incompatible_config =
      create_configuration!(recipient, provider, "model-incompatible", other_tag.id)

    chat = create_chat!(recipient, llm_configuration_id: incompatible_config.id)

    response =
      conn
      |> json_api_patch("/api/ash/chats/#{chat.id}", %{"bot_id" => bot.id})
      |> json_response(200)

    patched_chat = response_chat!(response, recipient)
    assert patched_chat.bot_id == bot.id
    assert patched_chat.llm_configuration_id == compatible_config.id
  end

  test "PATCH /api/ash/chats/:id manages chat tool bindings", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    chat = create_chat!(actor)

    tool_a =
      create_tool_instance!(actor,
        type: "mcp-http",
        name: "Tool A",
        alias: "web",
        config: %{"server_url" => "https://example.com/a"},
        secrets: %{"bearer_token" => "a"}
      )

    tool_b =
      create_tool_instance!(actor,
        type: "mcp-http",
        name: "Tool B",
        alias: "reader",
        config: %{"server_url" => "https://example.com/b"},
        secrets: %{"bearer_token" => "b"}
      )

    conn
    |> json_api_patch("/api/ash/chats/#{chat.id}", %{
      "tool_bindings" => [
        %{"tool_instance_id" => tool_a.id, "enabled" => true},
        %{"tool_instance_id" => tool_b.id, "enabled" => false}
      ]
    })
    |> json_response(200)

    bindings = chat_tool_bindings_with_alias!(chat.id, actor)

    assert Enum.map(bindings, &{&1.alias, &1.tool_instance_id, &1.enabled, &1.sequence}) == [
             {"web", tool_a.id, true, 0},
             {"reader", tool_b.id, false, 1}
           ]

    [first_binding | _] = bindings

    conn
    |> recycle()
    |> sign_in_conn(actor.username, password)
    |> json_api_patch("/api/ash/chats/#{chat.id}", %{
      "tool_bindings" => [
        %{
          "id" => first_binding.id,
          "tool_instance_id" => tool_b.id,
          "enabled" => false
        }
      ]
    })
    |> json_response(200)

    bindings = chat_tool_bindings_with_alias!(chat.id, actor)

    assert Enum.map(bindings, &{&1.alias, &1.tool_instance_id, &1.enabled, &1.sequence}) == [
             {"reader", tool_b.id, false, 0}
           ]
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

  test "DELETE /api/ash/chats/:id deletes dependent records and attachment files", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor)
    {:ok, first} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    {:ok, _second} =
      Threads.add_message(chat, :assistant, "World", actor: actor, parent_id: first.id)

    block = create_knowledge_block!(actor)
    create_chat_block_binding!(actor, chat, block)
    tool = create_tool_instance!(actor)
    create_chat_tool_binding!(actor, chat, tool)

    file = create_file!("delete.txt", "text/plain", "delete payload")

    {:ok, message_with_file} =
      Threads.add_message_to_end(chat, :user, "",
        actor: actor,
        contents: [
          %{kind: :text, content_text: "Delete with attachment"},
          %{kind: :media, file_id: file.id}
        ]
      )

    loaded =
      Ash.get!(ChatMessage, message_with_file.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    [step] = Enum.sort_by(loaded.steps || [], & &1.sequence)
    [item] = Enum.sort_by(step.items || [], & &1.sequence)
    media_content = Enum.find(item.contents || [], &(&1.kind == :media))

    delete_conn =
      conn
      |> json_api_delete("/api/ash/chats/#{chat.id}")

    assert delete_conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Chat, chat.id, actor: actor)

    assert [] =
             ChatMessage
             |> Ash.Query.filter(chat_id == ^chat.id)
             |> Ash.read!(actor: actor)

    assert [] =
             ChatKnowledgeBlock
             |> Ash.Query.filter(chat_id == ^chat.id)
             |> Ash.read!(actor: actor)

    assert [] =
             ChatToolBinding
             |> Ash.Query.filter(chat_id == ^chat.id)
             |> Ash.read!(actor: actor)

    assert {:error, _} = Ash.get(ChatMessageStep, step.id, actor: actor)
    assert {:error, _} = Ash.get(ChatMessageItem, item.id, actor: actor)
    assert {:error, _} = Ash.get(ChatMessageContent, media_content.id, actor: actor)
    assert {:error, _} = Ash.get(StoredFile, file.id, authorize?: false)
    assert payload_count(file.sha256) == 0
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

  defp create_configuration!(actor, provider, model_name, tag_id \\ nil, attrs \\ []) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          provider_id: provider.id,
          model_name: model_name,
          note: "cfg",
          parameters: %{},
          enabled: true,
          timeout_seconds: 300,
          tag_bindings:
            if(is_integer(tag_id), do: [%{llm_configuration_tag_id: tag_id}], else: nil)
        },
        Map.new(attrs)
      ),
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

  defp create_tool_instance!(actor, attrs \\ []) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          type: "native-agent-management",
          name: "Agent management",
          description: "",
          alias: "agent_management",
          config: %{},
          secrets: %{},
          max_output_tokens: 20_000
        },
        Map.new(attrs)
      ),
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

  defp chat_tool_bindings_with_alias!(chat_id, actor) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load([:alias])
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

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_file!(filename, mime_type, payload) do
    {:ok, file} =
      Files.create_from_upload(%{
        filename: filename,
        mime_type: mime_type,
        payload: payload
      })

    file
  end

  defp payload_count(sha256) do
    Db.repo().aggregate(
      from(payload in FilePayload, where: payload.sha256 == ^sha256),
      :count,
      :sha256
    )
  end
end
