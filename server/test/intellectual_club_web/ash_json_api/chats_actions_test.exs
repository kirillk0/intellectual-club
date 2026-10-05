defmodule IntellectualClubWeb.AshJsonApi.ChatsActionsTest do
  @moduledoc """
  Chat data actions exposed through the AshJsonApi endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

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

  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Files.GarbageCollector
  alias IntellectualClub.Tools.ChatToolBinding

  require Ash.Query

  describe "POST /api/ash/chats default configuration" do
    test "POST /api/ash/chats applies default configuration and preserves explicit null", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot = create_bot!(actor, name: "Assistant")
      provider = create_provider!(actor, name: "Provider", type: :openrouter_chat_completion)
      old_config = create_configuration!(actor, provider: provider, model_name: "model-old")
      latest_config = create_configuration!(actor, provider: provider, model_name: "model-new")

      create_empty_chat!(actor, bot_id: bot.id, llm_configuration_id: old_config.id)
      create_empty_chat!(actor, bot_id: bot.id, llm_configuration_id: latest_config.id)

      default_response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats",
          json_api_data("chats", %{"bot_id" => bot.id})
        )
        |> json_response(201)

      default_chat = response_chat!(default_response, actor)
      assert default_chat.llm_configuration_id == latest_config.id

      null_response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats",
          json_api_data("chats", %{
            "bot_id" => bot.id,
            "llm_configuration_id" => nil
          })
        )
        |> json_response(201)

      null_chat = response_chat!(null_response, actor)
      assert null_chat.llm_configuration_id == nil
    end

    test "POST /api/ash/chats scopes default configuration history by bot and no-bot chats",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot_a = create_bot!(actor, name: "Bot A")
      bot_b = create_bot!(actor, name: "Bot B")
      provider = create_provider!(actor, name: "Provider", type: :openrouter_chat_completion)
      config_a = create_configuration!(actor, provider: provider, model_name: "model-a")
      config_b = create_configuration!(actor, provider: provider, model_name: "model-b")

      config_old_no_bot =
        create_configuration!(actor, provider: provider, model_name: "model-old-no-bot")

      config_new_no_bot =
        create_configuration!(actor, provider: provider, model_name: "model-new-no-bot")

      create_empty_chat!(actor, bot_id: bot_a.id, llm_configuration_id: config_a.id)
      create_empty_chat!(actor, bot_id: bot_b.id, llm_configuration_id: config_b.id)
      create_empty_chat!(actor, llm_configuration_id: config_old_no_bot.id)
      create_empty_chat!(actor, llm_configuration_id: config_new_no_bot.id)

      bot_response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats",
          json_api_data("chats", %{"bot_id" => bot_a.id})
        )
        |> json_response(201)

      assert response_chat!(bot_response, actor).llm_configuration_id == config_a.id

      no_bot_response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post("/api/ash/chats", json_api_data("chats", %{}))
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
      provider = create_provider!(actor, name: "Provider", type: :openrouter_chat_completion)
      config_b = create_configuration!(actor, provider: provider, model_name: "model-b")
      config_a = create_configuration!(actor, provider: provider, model_name: "model-a")

      first_available_response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post("/api/ash/chats", json_api_data("chats", %{}))
        |> json_response(201)

      first_available_chat = response_chat!(first_available_response, actor)
      assert first_available_chat.llm_configuration_id == config_a.id
      refute first_available_chat.llm_configuration_id == config_b.id

      %{user: bot_actor, password: bot_password} = user_fixture()
      bot_conn = build_conn() |> sign_in_conn(bot_actor.username, bot_password)

      bot_provider =
        create_provider!(bot_actor, name: "Bot provider", type: :openrouter_chat_completion)

      fallback_config =
        create_configuration!(bot_actor, provider: bot_provider, model_name: "model-fallback")

      default_config =
        create_configuration!(bot_actor, provider: bot_provider, model_name: "model-default")

      bot =
        create_bot!(bot_actor,
          name: "Default bot",
          default_llm_configuration_id: default_config.id
        )

      bot_default_response =
        bot_conn
        |> json_api_post(
          "/api/ash/chats",
          json_api_data("chats", %{"bot_id" => bot.id})
        )
        |> json_response(201)

      bot_default_chat = response_chat!(bot_default_response, bot_actor)
      assert bot_default_chat.llm_configuration_id == default_config.id
      refute bot_default_chat.llm_configuration_id == fallback_config.id
    end

    test "POST /api/ash/chats uses bot default before compatible fallback", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      compatible_tag = create_configuration_tag!(actor, name: "Compatible")
      other_tag = create_configuration_tag!(actor, name: "Other")
      provider = create_provider!(actor, name: "Provider", type: :openrouter_chat_completion)

      _fallback_config =
        create_configuration!(actor,
          provider: provider,
          model_name: "compatible-model",
          tag_bindings: [%{llm_configuration_tag_id: compatible_tag.id}]
        )

      default_config =
        create_configuration!(actor,
          provider: provider,
          model_name: "default-model",
          tag_bindings: [%{llm_configuration_tag_id: other_tag.id}]
        )

      bot =
        create_bot!(actor,
          name: "Default bot",
          default_llm_configuration_id: default_config.id,
          compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: compatible_tag.id}]
        )

      response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats",
          json_api_data("chats", %{"bot_id" => bot.id})
        )
        |> json_response(201)

      chat = response_chat!(response, actor)
      assert chat.llm_configuration_id == default_config.id
    end

    test "POST /api/ash/chats keeps advanced default configuration precedence", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      provider = create_provider!(actor, name: "Provider", type: :openrouter_chat_completion)

      default_config =
        create_configuration!(actor, provider: provider, model_name: "model-default")

      latest_config = create_configuration!(actor, provider: provider, model_name: "model-latest")

      bot =
        create_bot!(actor, name: "History bot", default_llm_configuration_id: default_config.id)

      create_empty_chat!(actor, bot_id: bot.id, llm_configuration_id: latest_config.id)

      latest_response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats",
          json_api_data("chats", %{"bot_id" => bot.id})
        )
        |> json_response(201)

      assert response_chat!(latest_response, actor).llm_configuration_id == latest_config.id

      %{user: compatible_actor, password: compatible_password} = user_fixture()

      compatible_conn =
        build_conn() |> sign_in_conn(compatible_actor.username, compatible_password)

      compatible_tag = create_configuration_tag!(compatible_actor, name: "Compatible")
      other_tag = create_configuration_tag!(compatible_actor, name: "Other")

      compatible_provider =
        create_provider!(compatible_actor,
          name: "Compatible provider",
          type: :openrouter_chat_completion
        )

      compatible_config =
        create_configuration!(compatible_actor,
          provider: compatible_provider,
          model_name: "model-compatible",
          tag_bindings: [%{llm_configuration_tag_id: compatible_tag.id}]
        )

      incompatible_config =
        create_configuration!(compatible_actor,
          provider: compatible_provider,
          model_name: "model-incompatible",
          tag_bindings: [%{llm_configuration_tag_id: other_tag.id}]
        )

      compatible_bot =
        create_bot!(compatible_actor,
          name: "Compatible bot",
          compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: compatible_tag.id}]
        )

      create_empty_chat!(compatible_actor,
        bot_id: compatible_bot.id,
        llm_configuration_id: compatible_config.id
      )

      create_empty_chat!(compatible_actor,
        bot_id: compatible_bot.id,
        llm_configuration_id: incompatible_config.id
      )

      compatible_response =
        compatible_conn
        |> json_api_post(
          "/api/ash/chats",
          json_api_data("chats", %{"bot_id" => compatible_bot.id})
        )
        |> json_response(201)

      assert response_chat!(compatible_response, compatible_actor).llm_configuration_id ==
               compatible_config.id

      %{user: disabled_actor, password: disabled_password} = user_fixture()
      disabled_conn = build_conn() |> sign_in_conn(disabled_actor.username, disabled_password)
      disabled_compatible_tag = create_configuration_tag!(disabled_actor, name: "Compatible")
      disabled_other_tag = create_configuration_tag!(disabled_actor, name: "Other")

      disabled_provider =
        create_provider!(disabled_actor,
          name: "Disabled provider",
          type: :openrouter_chat_completion
        )

      _fallback_config =
        create_configuration!(disabled_actor,
          provider: disabled_provider,
          model_name: "model-compatible",
          tag_bindings: [%{llm_configuration_tag_id: disabled_compatible_tag.id}]
        )

      disabled_default_config =
        create_configuration!(disabled_actor,
          provider: disabled_provider,
          model_name: "model-disabled-default",
          tag_bindings: [%{llm_configuration_tag_id: disabled_other_tag.id}],
          enabled: false
        )

      disabled_bot =
        create_bot!(disabled_actor,
          name: "Disabled default bot",
          default_llm_configuration_id: disabled_default_config.id,
          compatible_configuration_tag_bindings: [
            %{llm_configuration_tag_id: disabled_compatible_tag.id}
          ]
        )

      disabled_default_response =
        disabled_conn
        |> json_api_post(
          "/api/ash/chats",
          json_api_data("chats", %{"bot_id" => disabled_bot.id})
        )
        |> json_response(201)

      assert response_chat!(disabled_default_response, disabled_actor).llm_configuration_id ==
               disabled_default_config.id

      %{user: no_bot_actor, password: no_bot_password} = user_fixture()
      no_bot_conn = build_conn() |> sign_in_conn(no_bot_actor.username, no_bot_password)

      no_bot_provider =
        create_provider!(no_bot_actor, name: "No bot provider", type: :openrouter_chat_completion)

      enabled_config =
        create_configuration!(no_bot_actor,
          provider: no_bot_provider,
          model_name: "model-enabled"
        )

      disabled_latest_config =
        create_configuration!(no_bot_actor,
          provider: no_bot_provider,
          model_name: "model-disabled-latest",
          tag_bindings: nil,
          enabled: false
        )

      create_empty_chat!(no_bot_actor, llm_configuration_id: disabled_latest_config.id)

      no_bot_response =
        no_bot_conn
        |> json_api_post("/api/ash/chats", json_api_data("chats", %{}))
        |> json_response(201)

      assert response_chat!(no_bot_response, no_bot_actor).llm_configuration_id ==
               enabled_config.id
    end
  end

  describe "PATCH /api/ash/chats/:id" do
    test "PATCH /api/ash/chats/:id adjusts incompatible configuration when bot changes", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      provider = create_provider!(actor, name: "Provider", type: :openrouter_chat_completion)
      old_tag = create_configuration_tag!(actor, name: "Old")
      new_tag = create_configuration_tag!(actor, name: "New")

      old_config =
        create_configuration!(actor,
          provider: provider,
          model_name: "old-model",
          tag_bindings: [%{llm_configuration_tag_id: old_tag.id}]
        )

      new_config =
        create_configuration!(actor,
          provider: provider,
          model_name: "new-model",
          tag_bindings: [%{llm_configuration_tag_id: new_tag.id}]
        )

      old_bot =
        create_bot!(actor,
          name: "Old bot",
          compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: old_tag.id}]
        )

      new_bot =
        create_bot!(actor,
          name: "New bot",
          compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: new_tag.id}]
        )

      create_empty_chat!(actor, bot_id: new_bot.id, llm_configuration_id: new_config.id)
      chat = create_empty_chat!(actor, bot_id: old_bot.id, llm_configuration_id: old_config.id)

      response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_patch(
          "/api/ash/chats/#{chat.id}",
          json_api_data("chats", %{"bot_id" => new_bot.id})
        )
        |> json_response(200)

      patched_chat = response_chat!(response, actor)
      assert patched_chat.bot_id == new_bot.id
      assert patched_chat.llm_configuration_id == new_config.id
    end

    test "PATCH /api/ash/chats/:id manages chat tool bindings", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      chat = create_empty_chat!(actor)

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
      |> json_api_patch(
        "/api/ash/chats/#{chat.id}",
        json_api_data("chats", %{
          "tool_bindings" => [
            %{"tool_instance_id" => tool_a.id, "enabled" => true},
            %{"tool_instance_id" => tool_b.id, "enabled" => false}
          ]
        })
      )
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
      |> json_api_patch(
        "/api/ash/chats/#{chat.id}",
        json_api_data("chats", %{
          "tool_bindings" => [
            %{
              "id" => first_binding.id,
              "tool_instance_id" => tool_b.id,
              "enabled" => false
            }
          ]
        })
      )
      |> json_response(200)

      bindings = chat_tool_bindings_with_alias!(chat.id, actor)

      assert Enum.map(bindings, &{&1.alias, &1.tool_instance_id, &1.enabled, &1.sequence}) == [
               {"reader", tool_b.id, false, 0}
             ]
    end
  end

  describe "shared bot compatible configuration tags" do
    setup do
      %{user: owner} = user_fixture()
      %{user: recipient} = recipient_fixture = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})
      owner_tag = create_configuration_tag!(owner, name: "Compatible")
      recipient_tag = create_configuration_tag!(recipient, name: "compatible")
      other_tag = create_configuration_tag!(recipient, name: "Other")

      bot =
        create_bot!(owner,
          compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: owner_tag.id}]
        )

      share_bot!(owner, bot, group)
      provider = create_provider!(recipient, type: :openrouter_chat_completion)

      compatible =
        create_configuration!(recipient,
          provider: provider,
          tag_bindings: [%{llm_configuration_tag_id: recipient_tag.id}]
        )

      incompatible =
        create_configuration!(recipient,
          provider: provider,
          tag_bindings: [%{llm_configuration_tag_id: other_tag.id}]
        )

      %{
        conn: sign_in_conn(build_conn(), recipient_fixture),
        recipient: recipient,
        bot: bot,
        compatible: compatible,
        incompatible: incompatible
      }
    end

    test "POST /api/ash/chats matches them to the actor's tags by name", ctx do
      response =
        ctx.conn
        |> json_api_post("/api/ash/chats", json_api_data("chats", %{"bot_id" => ctx.bot.id}))
        |> json_response(201)

      chat = response_chat!(response, ctx.recipient)
      assert {chat.bot_id, chat.llm_configuration_id} == {ctx.bot.id, ctx.compatible.id}
    end

    test "PATCH /api/ash/chats/:id matches them to the actor's tags by name", ctx do
      chat = create_empty_chat!(ctx.recipient, llm_configuration_id: ctx.incompatible.id)

      response =
        ctx.conn
        |> json_api_patch(
          "/api/ash/chats/#{chat.id}",
          json_api_data("chats", %{"bot_id" => ctx.bot.id})
        )
        |> json_response(200)

      chat = response_chat!(response, ctx.recipient)
      assert {chat.bot_id, chat.llm_configuration_id} == {ctx.bot.id, ctx.compatible.id}
    end
  end

  describe "copy, continue and branch" do
    test "POST /api/ash/chats/:id/copy copies block and tool bindings in order and rejects inaccessible source",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      %{user: other, password: other_password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      source = create_empty_chat!(actor)
      block = create_knowledge_block!(actor, name: "Chat block", content: "Knowledge")

      tool =
        create_tool_instance!(actor, type: "native-agent-management")

      other_block = create_knowledge_block!(actor)
      other_tool = create_tool_instance!(actor, alias: "other_tool")
      create_chat_block_binding!(actor, source, block, enabled: false, sequence: 7)
      create_chat_block_binding!(actor, source, other_block, sequence: 2)
      create_chat_tool_binding!(actor, source, tool, sequence: 3)
      create_chat_tool_binding!(actor, source, other_tool, enabled: false, sequence: 5)

      response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats/#{source.id}/copy",
          json_api_data("chats", %{})
        )
        |> json_response(201)

      target_id = response |> get_in(["data", "id"]) |> String.to_integer()

      assert chat_binding_settings!(actor, target_id) == %{
               blocks: [{other_block.id, true, 2}, {block.id, false, 7}],
               tools: [{tool.id, true, 3}, {other_tool.id, false, 5}]
             }

      inaccessible_conn =
        build_conn()
        |> sign_in_conn(other.username, other_password)
        |> json_api_post(
          "/api/ash/chats/#{source.id}/copy",
          json_api_data("chats", %{})
        )

      assert inaccessible_conn.status in [400, 403, 404, 422]
    end

    test "POST /api/ash/chats/:id/continue copies the active branch", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      source = create_empty_chat!(actor)

      {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)
      {:ok, active} = Threads.add_message_to_end(source, :assistant, "Active", actor: actor)

      {:ok, _inactive} =
        Threads.add_message(source, :assistant, "Inactive", actor: actor, parent_id: root.id)

      {:ok, _meta} = Threads.activate_branch(source.id, active.id, actor)

      response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats/#{source.id}/continue",
          json_api_data("chats", %{})
        )
        |> json_response(201)

      target_id = response |> get_in(["data", "id"]) |> String.to_integer()

      assert messages_for_chat!(actor, target_id) |> Enum.map(&message_text/1) == [
               "Root",
               "Active"
             ]
    end

    test "POST /api/ash/chats/:id/branch handles assistant and user replacement branches", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      source = create_empty_chat!(actor)

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
        |> json_api_post(
          "/api/ash/chats/#{source.id}/branch",
          json_api_data("chats", %{
            "message_id" => assistant.id
          })
        )
        |> json_response(201)

      assistant_target_id = assistant_response |> get_in(["data", "id"]) |> String.to_integer()

      assert messages_for_chat!(actor, assistant_target_id) |> Enum.map(&message_text/1) == [
               "Root"
             ]

      user_response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats/#{source.id}/branch",
          json_api_data("chats", %{
            "message_id" => selected_user.id,
            "replacement_contents" => [%{"kind" => "text", "content_text" => "Replacement"}]
          })
        )
        |> json_response(201)

      user_target_id = user_response |> get_in(["data", "id"]) |> String.to_integer()

      assert messages_for_chat!(actor, user_target_id) |> Enum.map(&message_text/1) == [
               "Root",
               "Answer",
               "Replacement"
             ]

      rejected =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chats/#{source.id}/branch",
          json_api_data("chats", %{
            "message_id" => inactive.id
          })
        )

      assert rejected.status in [400, 422]
    end
  end

  describe "branch navigation" do
    test "PATCH /api/ash/chats/:id/switch-branch and activate-branch change active leaf", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      chat = create_empty_chat!(actor)

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
      |> json_api_patch(
        "/api/ash/chats/#{chat.id}/switch-branch",
        json_api_data("chats", %{
          "message_id" => first.id,
          "target_id" => second.id
        })
      )
      |> json_response(200)

      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == second_leaf.id

      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_patch(
        "/api/ash/chats/#{chat.id}/activate-branch",
        json_api_data("chats", %{
          "message_id" => first.id
        })
      )
      |> json_response(200)

      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == first.id
    end
  end

  describe "POST /api/ash/chat-messages/add-user" do
    test "POST /api/ash/chat-messages/add-user creates content-bearing user messages", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      chat = create_empty_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

      response =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> json_api_post(
          "/api/ash/chat-messages/add-user",
          json_api_data("chat-messages", %{
            "chat_id" => chat.id,
            "parent_id" => root.id,
            "use_active_leaf_parent" => false,
            "contents" => [%{"kind" => "text", "content_text" => "Follow-up"}]
          })
        )
        |> json_response(201)

      message_id = response |> get_in(["data", "id"]) |> String.to_integer()

      message =
        Ash.get!(ChatMessage, message_id, actor: actor)
        |> Ash.load!([steps: [items: [:contents]]], actor: actor)

      assert message.role == :user
      assert message.parent_id == root.id
      assert message_text(message) == "Follow-up"
    end
  end

  describe "DELETE /api/ash/chats/:id" do
    test "DELETE /api/ash/chats/:id deletes dependent records and attachment files", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_empty_chat!(actor)
      {:ok, first} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      {:ok, _second} =
        Threads.add_message(chat, :assistant, "World", actor: actor, parent_id: first.id)

      block = create_knowledge_block!(actor, name: "Chat block", content: "Knowledge")
      create_chat_block_binding!(actor, chat, block, enabled: false, sequence: 7)

      tool =
        create_tool_instance!(actor, type: "native-agent-management")

      create_chat_tool_binding!(actor, chat, tool, sequence: 3)

      file =
        create_file!(filename: "delete.txt", mime_type: "text/plain", payload: "delete payload")

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
      assert {:ok, :deleted} = GarbageCollector.collect_sha256(file.sha256)
      refute FilesystemStorage.exists?(file.sha256)
    end
  end

  defp response_chat!(response, actor) do
    response
    |> get_in(["data", "id"])
    |> String.to_integer()
    |> then(&Ash.get!(Chat, &1, actor: actor))
  end

  defp chat_tool_bindings_with_alias!(chat_id, actor) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load([:alias])
    |> Ash.read!(actor: actor)
  end

  defp message_text(%ChatMessage{} = message) do
    Previews.message_preview_text(message)
  end
end
