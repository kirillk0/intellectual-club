defmodule IntellectualClubWeb.Bff.ChatStateTest do
  @moduledoc """
  Chat state BFF endpoints: lean message content, settings, prompt context, message tree and tool result previews.
  """

  use IntellectualClubWeb.ConnCase, async: true

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmConfigurationTag
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolFunction
  alias IntellectualClub.Tools.ToolInstance
  alias IntellectualClubWeb.Bff.ChatBranchPayload

  describe "GET /api/bff/chat-state/:id" do
    test "returns lean content for markdown user message", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      markdown = """
      # Title

      Hello **world**.
      """

      {:ok, _message} = Threads.add_message_to_end(chat, :user, markdown, actor: actor)

      conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}")
      payload = json_response(conn, 200)

      branch = Map.get(payload, "branch", [])
      assert is_list(branch)
      assert length(branch) >= 1

      first = List.first(branch)
      texts = all_text_contents(first)
      refute Map.has_key?(first, "steps")
      assert Enum.any?(texts, &String.contains?(&1, "# Title"))
      assert Enum.any?(texts, &String.contains?(&1, "**world**"))
    end

    test "includes lean content, usage, and working summary", %{
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

      long_text = String.duplicate("A", 220) <> "TAIL"

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hi", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message(chat, :assistant, long_text, actor: actor, parent_id: user_message.id)

      conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}")
      payload = json_response(conn, 200)

      branch = Map.get(payload, "branch", [])

      assistant =
        Enum.find(branch, fn message ->
          message["id"] == assistant_message.id
        end)

      assert is_map(assistant)
      assert is_binary(assistant["finished_at"])
      refute Map.has_key?(assistant, "steps")
      assert get_in(assistant, ["working", "step_count"]) == 1
      assert is_binary(get_in(assistant, ["usage", "latest_step", "finished_at"]))

      assert Enum.any?(all_text_contents(assistant), &String.contains?(&1, "TAIL"))
    end

    test "keeps partial answers visible after cancel and error", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      for {status, partial_text} <- [
            {:canceled, "Partial answer before cancel"},
            {:error, "Partial answer before error"}
          ] do
        chat =
          Chat
          |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
          |> Ash.create!(actor: actor)

        {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hi", actor: actor)

        assistant_message =
          ChatMessage
          |> Ash.Changeset.for_create(
            :add_message,
            %{
              chat_id: chat.id,
              role: :assistant,
              parent_id: user_message.id,
              status: status,
              error_detail: if(status == :error, do: "Stream failed", else: nil),
              token_count: 3
            },
            actor: actor
          )
          |> Ash.create!(actor: actor)

        step = create_chat_message_step!(assistant_message.id, 1, status, actor)
        item = create_chat_message_item!(step.id, 1, :answer, actor)
        _content = create_chat_message_text_content!(item.id, 1, partial_text, actor)

        payload =
          conn
          |> get(~p"/api/bff/chat-state/#{chat.id}")
          |> json_response(200)

        assistant =
          Enum.find(payload["branch"] || [], &(&1["id"] == assistant_message.id))

        assert assistant["status"] == Atom.to_string(status)
        assert partial_text in all_text_contents(assistant)
      end
    end

    test "lean content describes mixed and empty persisted display items", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hi", actor: actor)

      assistant_message =
        ChatMessage
        |> Ash.Changeset.for_create(
          :add_message,
          %{
            chat_id: chat.id,
            role: :assistant,
            parent_id: user_message.id,
            status: :done,
            token_count: 3
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      step = create_chat_message_step!(assistant_message.id, 1, :done, actor)
      answer = create_chat_message_item!(step.id, 1, :answer, actor)
      _answer_content = create_chat_message_text_content!(answer.id, 1, "Ordinary answer", actor)
      _empty_summary = create_chat_message_item!(step.id, 2, :handoff_summary, actor)

      payload =
        conn
        |> get(~p"/api/bff/chat-state/#{chat.id}")
        |> json_response(200)

      assistant = Enum.find(payload["branch"] || [], &(&1["id"] == assistant_message.id))

      assert Enum.map(assistant["content"]["items"], & &1["item_type"]) == [
               "answer",
               "handoff_summary"
             ]

      assert Enum.all?(assistant["content"]["items"], fn item ->
               Enum.all?(
                 ["step_id", "step_sequence", "item_id", "item_sequence", "item_type"],
                 &Map.has_key?(item, &1)
               )
             end)

      assert Enum.map(assistant["content"]["parts"], & &1["text"]) == ["Ordinary answer"]
    end

    test "lean runtime content describes an empty handoff summary item" do
      %{user: actor} = user_fixture()

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hi", actor: actor)

      assistant_message =
        ChatMessage
        |> Ash.Changeset.for_create(
          :create_generating_assistant,
          %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      runtime_step =
        RuntimeTrace.new_step(sequence: 1)
        |> RuntimeTrace.apply_event({:ensure_item, "summary", :handoff_summary, 1})
        |> RuntimeTrace.snapshot()

      payload =
        ChatBranchPayload.message(assistant_message, actor,
          runtime_steps_by_message_id: %{assistant_message.id => runtime_step}
        )

      assert payload.content.parts == []

      assert [
               %{
                 step_id: -1,
                 step_sequence: 1,
                 item_id: -101,
                 item_sequence: 1,
                 item_type: "handoff_summary"
               }
             ] = payload.content.items
    end

    test "includes retry error diagnostics in working summary", %{
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

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hi", actor: actor)

      assistant_message =
        ChatMessage
        |> Ash.Changeset.for_create(
          :create_generating_assistant,
          %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      retry_step = create_chat_message_step!(assistant_message.id, 1, :error, actor)

      retry_item =
        create_chat_message_item!(retry_step.id, 1, :error, actor)

      retry_text = "Transient provider error on attempt 1. Retrying.\n\nTemporary network outage"
      create_chat_message_text_content!(retry_item.id, 1, retry_text, actor)

      create_chat_message_opaque_content!(
        retry_item.id,
        10_000,
        %{
          "attempt" => 1,
          "retry_delay_ms" => 0,
          "error_kind" => "network",
          "retryable" => true
        },
        actor
      )

      _active_step = create_chat_message_step!(assistant_message.id, 2, :waiting_provider, actor)

      conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}")
      payload = json_response(conn, 200)

      assistant =
        payload
        |> Map.get("branch", [])
        |> Enum.find(fn message -> message["id"] == assistant_message.id end)

      assert is_map(assistant)
      refute Map.has_key?(assistant, "steps")
      assert get_in(assistant, ["working", "step_count"]) == 2
      assert get_in(assistant, ["working", "latest_step_sequence"]) == 2
      assert get_in(assistant, ["working", "latest_step_status"]) == "waiting_provider"
      assert get_in(assistant, ["working", "retry_error_count"]) == 1
      assert get_in(assistant, ["working", "latest_retry_error_text"]) == retry_text
      assert get_in(assistant, ["working", "latest_retry_error_step_sequence"]) == 1
      assert is_binary(get_in(assistant, ["working", "latest_retry_error_at"]))
    end
  end

  describe "GET /api/bff/chat-state/:id/settings" do
    test "includes context settings in options", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      provider = create_provider!(actor, name: "Provider A", type: :openrouter_chat_completion)

      config =
        create_configuration!(actor,
          provider: provider,
          model_name: "model-x",
          context_length: 8192,
          timeout_seconds: 300
        )

      bot =
        create_bot!(actor,
          name: "Agent bot",
          context_soft_limit_percent: 75,
          history_mode: :agent
        )

      no_bot_chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: ""},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{
            note: "",
            bot_id: bot.id,
            llm_configuration_id: config.id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}/settings")
      payload = json_response(conn, 200)

      bots = get_in(payload, ["options", "bots"]) || []
      llm_configs = get_in(payload, ["options", "llm_configurations"]) || []

      bot_payload = Enum.find(bots, fn item -> item["id"] == bot.id end) || %{}
      cfg_payload = Enum.find(llm_configs, fn item -> item["id"] == config.id end) || %{}

      assert bot_payload["context_soft_limit_percent"] == 75
      assert bot_payload["history_mode"] == "agent"
      assert is_binary(bot_payload["created_at"])
      assert is_binary(bot_payload["updated_at"])
      assert bot_payload["sort_activity_at"] == bot_payload["updated_at"]

      assert get_in(payload, ["options", "no_bot_last_activity_at"]) ==
               IntellectualClubWeb.Bff.Serializer.datetime_iso(
                 no_bot_chat.updated_at || no_bot_chat.created_at
               )

      assert cfg_payload["context_length"] == 8192
      refute Map.has_key?(cfg_payload, "supports_steering")
    end

    test "includes configuration and bot tag metadata in options",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      tag =
        LlmConfigurationTag
        |> Ash.Changeset.for_create(:create, %{name: "Compatible"}, actor: actor)
        |> Ash.create!(actor: actor)

      provider = create_provider!(actor, name: "Provider tags", type: :openrouter_chat_completion)

      config =
        LlmConfiguration
        |> Ash.Changeset.for_create(
          :create,
          %{
            provider_id: provider.id,
            model_name: "model-tags",
            note: "cfg",
            parameters: %{},
            enabled: true,
            timeout_seconds: 300,
            tag_bindings: [%{llm_configuration_tag_id: tag.id}]
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      bot =
        Bot
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Tagged bot",
            compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: tag.id}]
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{
            note: "",
            bot_id: bot.id,
            llm_configuration_id: config.id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      payload =
        conn
        |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
        |> json_response(200)

      bot_payload =
        Enum.find(get_in(payload, ["options", "bots"]) || [], &(&1["id"] == bot.id)) || %{}

      cfg_payload =
        Enum.find(
          get_in(payload, ["options", "llm_configurations"]) || [],
          &(&1["id"] == config.id)
        ) || %{}

      assert bot_payload["compatible_configuration_tag_ids"] == [tag.id]
      assert bot_payload["compatible_configuration_tag_names"] == ["Compatible"]
      assert cfg_payload["tag_ids"] == [tag.id]
      assert cfg_payload["tag_names"] == ["Compatible"]
    end

    test "includes user prompt sources", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      user_block =
        KnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{name: "User setting block", version: "v1", content: "always include me"},
          actor: actor
        )
        |> Ash.create!()

      _ =
        UserKnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{knowledge_block_id: user_block.id, enabled: true, sequence: 10},
          actor: actor
        )
        |> Ash.create!()

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}/settings")
      payload = json_response(conn, 200)

      user_sources = get_in(payload, ["prompt_sources", "user"]) || []
      assert length(user_sources) == 1

      [first_source] = user_sources
      assert get_in(first_source, ["knowledge_block", "id"]) == user_block.id
    end

    test "orders configuration top blocks before bot blocks",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      top_block =
        KnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Config top", version: "v1", content: "config-top"},
          actor: actor
        )
        |> Ash.create!()

      bot_block =
        KnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Bot block", version: "v1", content: "bot"},
          actor: actor
        )
        |> Ash.create!()

      bottom_block =
        KnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Config bottom", version: "v1", content: "config-bottom"},
          actor: actor
        )
        |> Ash.create!()

      bot =
        create_bot!(actor,
          name: "Prompt bot",
          context_soft_limit_percent: 80,
          history_mode: :agent
        )

      provider = create_provider!(actor, name: "Provider A", type: :openrouter_chat_completion)

      config =
        create_configuration!(actor,
          provider: provider,
          model_name: "model-top",
          context_length: 8192,
          timeout_seconds: 300
        )

      _ =
        IntellectualClub.Bots.BotKnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{bot_id: bot.id, knowledge_block_id: bot_block.id, enabled: true, sequence: 10},
          actor: actor
        )
        |> Ash.create!()

      _ =
        LlmConfigurationKnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{
            llm_configuration_id: config.id,
            knowledge_block_id: top_block.id,
            selection: :top,
            enabled: true,
            sequence: 0
          },
          actor: actor
        )
        |> Ash.create!()

      _ =
        LlmConfigurationKnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{
            llm_configuration_id: config.id,
            knowledge_block_id: bottom_block.id,
            selection: :bottom,
            enabled: true,
            sequence: 1
          },
          actor: actor
        )
        |> Ash.create!()

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{
            note: "",
            bot_id: bot.id,
            llm_configuration_id: config.id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, _message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}/settings")
      payload = json_response(conn, 200)

      assert Regex.match?(
               ~r/# Config top.*# Bot block.*# Config bottom/s,
               payload["compiled_prompt_text"] || ""
             )

      assert Enum.map(
               get_in(payload, ["prompt_sources", "configuration"]) || [],
               & &1["selection"]
             ) ==
               [
                 "top",
                 "bottom"
               ]

      prompt_blocks = payload["prompt_blocks"] || []

      assert Enum.map(prompt_blocks, &get_in(&1, ["knowledge_block", "name"])) == [
               "Config top",
               "Bot block",
               "Config bottom"
             ]

      assert Enum.map(prompt_blocks, & &1["source"]) == ["config", "bot", "config"]
      assert Enum.map(prompt_blocks, & &1["selection"]) == ["top", nil, "bottom"]
      assert Enum.map(prompt_blocks, & &1["prompt_order"]) == [0, 1, 2]
    end

    test "includes image metadata in bot and knowledge block options",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      assert {:ok, bot_file} =
               Files.create_from_upload(%{
                 filename: "bot.png",
                 mime_type: "image/png",
                 payload: png_1x1()
               })

      assert {:ok, block_file} =
               Files.create_from_upload(%{
                 filename: "block.png",
                 mime_type: "image/png",
                 payload: png_1x1()
               })

      bot =
        create_bot!(actor,
          name: "Image bot",
          context_soft_limit_percent: 80,
          history_mode: :agent
        )
        |> then(fn bot ->
          bot
          |> Ash.Changeset.for_update(:attach_image_file, %{image_file_id: bot_file.id},
            actor: actor
          )
          |> Ash.update!(actor: actor)
        end)

      block =
        KnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Image block", version: "v1", content: "content"},
          actor: actor
        )
        |> Ash.create!(actor: actor)
        |> then(fn block ->
          block
          |> Ash.Changeset.for_update(
            :attach_image_file,
            %{image_file_id: block_file.id},
            actor: actor
          )
          |> Ash.update!(actor: actor)
        end)

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}/settings")
      payload = json_response(conn, 200)

      bot_payload =
        Enum.find(get_in(payload, ["options", "bots"]) || [], fn item ->
          item["id"] == bot.id
        end) || %{}

      block_payload =
        Enum.find(get_in(payload, ["options", "knowledge_blocks"]) || [], fn item ->
          item["id"] == block.id
        end) || %{}

      assert get_in(bot_payload, ["image", "filename"]) == "bot.png"
      assert get_in(bot_payload, ["image", "url"]) == "/api/bff/bots/#{bot.id}/image"
      assert get_in(block_payload, ["image", "filename"]) == "block.png"

      assert get_in(block_payload, ["image", "url"]) ==
               "/api/bff/knowledge-blocks/#{block.id}/image"
    end

    test "includes chat tool bindings and resolved active tools",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot =
        create_bot!(actor, name: "Tool bot", context_soft_limit_percent: 80, history_mode: :agent)

      base_tool =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "mcp-http",
            name: "Base tool",
            config: %{"server_url" => "https://example.com/base"},
            secrets: %{"bearer_token" => "base"}
          },
          actor: actor
        )
        |> Ash.create!()

      chat_tool =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "native-artifact-reader",
            name: "Chat tool",
            alias: "web",
            config: %{},
            secrets: %{}
          },
          actor: actor
        )
        |> Ash.create!()

      _ =
        BotToolBinding
        |> Ash.Changeset.for_create(
          :create,
          %{
            bot_id: bot.id,
            tool_instance_id: base_tool.id,
            sharing_mode: :shared,
            enabled: true,
            sequence: 0
          },
          actor: actor
        )
        |> Ash.create!()

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      _ =
        ChatToolBinding
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_id: chat.id,
            tool_instance_id: chat_tool.id,
            enabled: true,
            sequence: 0
          },
          actor: actor
        )
        |> Ash.create!()

      payload =
        conn
        |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
        |> json_response(200)

      assert get_in(payload, ["missing_required_per_user_tool_aliases"]) == []
      assert get_in(payload, ["artifact_tools_available"]) == true

      assert Enum.map(get_in(payload, ["chat_tool_bindings"]) || [], fn item ->
               {item["alias"], item["tool_instance_id"], item["enabled"], item["sequence"]}
             end) == [{"web", chat_tool.id, true, 0}]

      assert Enum.any?(get_in(payload, ["active_tool_instances"]) || [], fn item ->
               item["id"] == chat_tool.id and item["name"] == "Chat tool"
             end)

      assert Enum.any?(get_in(payload, ["options", "tool_instances"]) || [], fn item ->
               item["id"] == chat_tool.id and item["can_edit"] == true
             end)
    end

    test "returns only effective active tool bindings", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot =
        Bot
        |> Ash.Changeset.for_create(:create, %{name: "Tool state bot"}, actor: actor)
        |> Ash.create!(actor: actor)

      bot_tool =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "mcp-http",
            name: "Bot Tool",
            alias: "web",
            config: %{"server_url" => "https://example.com/bot"},
            secrets: %{"bearer_token" => "bot"}
          },
          actor: actor
        )
        |> Ash.create!()

      chat_tool =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "native-web-search",
            name: "Chat Tool",
            alias: "web",
            config: %{},
            secrets: %{"token" => "chat"}
          },
          actor: actor
        )
        |> Ash.create!()

      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: bot_tool.id,
          sharing_mode: :shared,
          enabled: true,
          sequence: 10
        },
        actor: actor
      )
      |> Ash.create!()

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{bot_id: bot.id, note: ""},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      ChatToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, tool_instance_id: chat_tool.id, enabled: true, sequence: 0},
        actor: actor
      )
      |> Ash.create!()

      payload =
        conn
        |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
        |> json_response(200)

      assert [%{"alias" => "web", "source" => "chat", "tool_instance" => tool_payload}] =
               payload["active_tool_bindings"]

      assert tool_payload["id"] == chat_tool.id
      assert tool_payload["name"] == "Chat Tool"
      assert tool_payload["type"] == "native-web-search"
      assert hd(payload["active_tool_bindings"])["background_functions_unavailable"] == false
    end

    test "marks bindings with gated background functions", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      outlet =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "outlet",
            name: "Background outlet",
            alias: "outlet",
            config: %{},
            secrets: %{"token" => "background-outlet-token"}
          },
          actor: actor
        )
        |> Ash.create!()

      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: outlet.id,
          name: "run_job",
          description: "Run a job.",
          parameters_schema: %{"type" => "object", "properties" => %{}},
          enabled: true
        },
        actor: actor
      )
      |> Ash.create!()

      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: outlet.id,
          name: "queue_job",
          description: "Run a job in the background.",
          parameters_schema: %{"type" => "object", "properties" => %{}},
          enabled: true,
          execution_mode: :background,
          target_function_name: "run_job"
        },
        actor: actor
      )
      |> Ash.create!()

      ChatToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, tool_instance_id: outlet.id, enabled: true, sequence: 0},
        actor: actor
      )
      |> Ash.create!()

      payload =
        conn
        |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
        |> json_response(200)

      assert [
               %{
                 "alias" => "outlet",
                 "background_functions_unavailable" => true,
                 "tool_instance" => %{"id" => outlet_id}
               }
             ] = payload["active_tool_bindings"]

      assert outlet_id == outlet.id

      status_provider =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "native-agent-management",
            name: "Background status provider",
            alias: "agent",
            config: %{},
            secrets: %{}
          },
          actor: actor
        )
        |> Ash.create!()

      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: status_provider.id,
          name: "check_background_task_status",
          description: "Check a background task.",
          parameters_schema: %{"type" => "object", "properties" => %{}},
          enabled: true
        },
        actor: actor
      )
      |> Ash.create!()

      ChatToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, tool_instance_id: status_provider.id, enabled: true, sequence: 1},
        actor: actor
      )
      |> Ash.create!()

      refreshed_payload =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
        |> json_response(200)

      refute Enum.any?(
               refreshed_payload["active_tool_bindings"],
               & &1["background_functions_unavailable"]
             )
    end
  end

  describe "GET /api/bff/chat-state/:id/prompt-context" do
    test "returns only prompt-related payload", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      block =
        KnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Config prompt block", version: "v1", content: "config prompt"},
          actor: actor
        )
        |> Ash.create!()

      provider =
        create_provider!(actor, name: "Prompt Provider", type: :openrouter_chat_completion)

      config =
        create_configuration!(actor,
          provider: provider,
          model_name: "prompt-model",
          context_length: 4096,
          timeout_seconds: 300
        )

      _ =
        LlmConfigurationKnowledgeBlock
        |> Ash.Changeset.for_create(
          :create,
          %{
            llm_configuration_id: config.id,
            knowledge_block_id: block.id,
            selection: :top,
            enabled: true,
            sequence: 0
          },
          actor: actor
        )
        |> Ash.create!()

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{
            note: "",
            llm_configuration_id: config.id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      tool =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "mcp-http",
            name: "Prompt MCP",
            description: "Use from prompt modal.\nLiteral {{tool_target}}.",
            alias: "prompt_mcp",
            config: %{"server_url" => "https://example.com/mcp"},
            secrets: %{}
          },
          actor: actor
        )
        |> Ash.create!()

      _enabled_function =
        ToolFunction
        |> Ash.Changeset.for_create(
          :create,
          %{
            tool_instance_id: tool.id,
            name: "search_docs",
            description: "Search project docs.",
            parameters_schema: %{"type" => "object"},
            enabled: true,
            discovered_at: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create!()

      _disabled_function =
        ToolFunction
        |> Ash.Changeset.for_create(
          :create,
          %{
            tool_instance_id: tool.id,
            name: "disabled_tool",
            description: "Disabled tool.",
            parameters_schema: %{"type" => "object"},
            enabled: false,
            discovered_at: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create!()

      _tool_binding =
        ChatToolBinding
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_id: chat.id,
            tool_instance_id: tool.id,
            enabled: true,
            sequence: 0
          },
          actor: actor
        )
        |> Ash.create!()

      {:ok, _message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      payload =
        conn
        |> get(~p"/api/bff/chat-state/#{chat.id}/prompt-context")
        |> json_response(200)

      assert get_in(payload, [
               "prompt_sources",
               "configuration",
               Access.at(0),
               "knowledge_block",
               "id"
             ]) ==
               block.id

      assert Enum.map(payload["prompt_blocks"] || [], &get_in(&1, ["knowledge_block", "name"])) ==
               [
                 "Config prompt block"
               ]

      assert Enum.map(payload["prompt_blocks"] || [], & &1["prompt_order"]) == [0]

      assert is_binary(payload["compiled_prompt_text"])
      assert String.contains?(payload["compiled_prompt_text"], "config prompt")
      assert String.contains?(payload["compiled_prompt_text"], "# Available tool instances")
      assert String.contains?(payload["compiled_prompt_text"], "## Tool instance `prompt_mcp`")
      assert String.contains?(payload["compiled_prompt_text"], "Type: MCP HTTP (mcp-http)")
      assert String.contains?(payload["compiled_prompt_text"], "`prompt_mcp__search_docs`")

      assert String.contains?(
               payload["compiled_prompt_text"],
               "Use from prompt modal.\nLiteral {{tool_target}}."
             )

      refute String.contains?(payload["compiled_prompt_text"], "prompt_mcp__disabled_tool")
      assert payload["counters"]["history_message_count"] == 1
      refute Map.has_key?(payload["counters"], "total_token_count")
      refute Map.has_key?(payload, "branch")
      refute Map.has_key?(payload, "options")

      state_payload =
        conn
        |> recycle()
        |> sign_in_conn(actor.username, password)
        |> get(~p"/api/bff/chat-state/#{chat.id}/settings")
        |> json_response(200)

      assert String.contains?(state_payload["compiled_prompt_text"], "# Available tool instances")
      assert String.contains?(state_payload["compiled_prompt_text"], "`prompt_mcp__search_docs`")

      assert Enum.map(
               state_payload["prompt_blocks"] || [],
               &get_in(&1, ["knowledge_block", "name"])
             ) == ["Config prompt block"]
    end
  end

  describe "GET /api/bff/chat-state/:id/message-tree" do
    test "returns active and inactive messages", %{
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
        Threads.add_message(chat, :user, "Inactive follow-up",
          actor: actor,
          parent_id: inactive.id
        )

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
  end

  describe "tool result previews" do
    test "state truncates tool_result text, strips bulky opaque payloads, and full endpoint returns complete text",
         %{conn: conn} do
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

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message(chat, :assistant, "Answer",
          actor: actor,
          parent_id: user_message.id
        )

      assistant_with_steps =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      step = List.first(assistant_with_steps.steps || [])
      assert is_map(step)

      tool_call_item =
        ChatMessageItem
        |> Ash.Changeset.for_create(
          :create,
          %{chat_message_step_id: step.id, sequence: 99, type: :tool_call},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      item =
        ChatMessageItem
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_step_id: step.id,
            sequence: 100,
            type: :tool_result,
            tool_call_item_id: tool_call_item.id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      long_text =
        [
          "line 1 - " <> String.duplicate("A", 160),
          "line 2 - " <> String.duplicate("B", 160),
          "line 3 - " <> String.duplicate("C", 160),
          "line 4 - " <> String.duplicate("D", 160),
          "line 5 - " <> String.duplicate("E", 160),
          "line 6 - " <> String.duplicate("F", 160)
        ]
        |> Enum.join("\n")

      content =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: item.id,
            sequence: 1,
            kind: :text,
            content_text: long_text
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      chat_style_opaque =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: item.id,
            sequence: 2,
            kind: :opaque,
            content_json: %{
              "tool_call_id" => "call_chat",
              "name" => "reader__read_url",
              "raw" => %{"content" => [%{"type" => "text", "text" => long_text}]}
            }
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      responses_item =
        ChatMessageItem
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_step_id: step.id,
            sequence: 101,
            type: :tool_result,
            tool_call_item_id: tool_call_item.id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      responses_text_content =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: responses_item.id,
            sequence: 1,
            kind: :text,
            content_text: long_text
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      responses_style_opaque =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: responses_item.id,
            sequence: 2,
            kind: :opaque,
            content_json: %{
              "responses_item" => %{
                "type" => "function_call_output",
                "id" => "fco_123",
                "call_id" => "call_resp",
                "output" => long_text
              },
              "raw" => %{"output" => long_text}
            }
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      reasoning_item =
        ChatMessageItem
        |> Ash.Changeset.for_create(
          :create,
          %{chat_message_step_id: step.id, sequence: 102, type: :reasoning},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      _reasoning_text =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: reasoning_item.id,
            sequence: 1,
            kind: :text,
            content_text: "Reasoning summary"
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      reasoning_opaque =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: reasoning_item.id,
            sequence: 2,
            kind: :opaque,
            content_json: %{
              "type" => "reasoning",
              "id" => "rs_123",
              "encrypted_content" => String.duplicate("opaque", 200)
            }
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      working =
        conn
        |> get(~p"/api/bff/chat-messages/#{assistant_message.id}/working")
        |> json_response(200)

      step_payload = working["step"] || %{}
      step_payloads = [step_payload]

      preview_content =
        step_payloads
        |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
        |> Enum.filter(fn i -> Map.get(i, "type") == "tool_result" end)
        |> Enum.flat_map(fn i -> Map.get(i, "contents", []) end)
        |> Enum.find(fn c -> Map.get(c, "id") == content.id end)

      chat_style_preview =
        step_payloads
        |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
        |> Enum.filter(fn i -> Map.get(i, "type") == "tool_result" end)
        |> Enum.flat_map(fn i -> Map.get(i, "contents", []) end)
        |> Enum.find(fn c -> Map.get(c, "id") == chat_style_opaque.id end)

      responses_text_preview =
        step_payloads
        |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
        |> Enum.filter(fn i -> Map.get(i, "type") == "tool_result" end)
        |> Enum.flat_map(fn i -> Map.get(i, "contents", []) end)
        |> Enum.find(fn c -> Map.get(c, "id") == responses_text_content.id end)

      responses_style_preview =
        step_payloads
        |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
        |> Enum.filter(fn i -> Map.get(i, "type") == "tool_result" end)
        |> Enum.flat_map(fn i -> Map.get(i, "contents", []) end)
        |> Enum.find(fn c -> Map.get(c, "id") == responses_style_opaque.id end)

      reasoning_contents =
        step_payloads
        |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
        |> Enum.find(fn i -> Map.get(i, "id") == reasoning_item.id end)
        |> then(&(&1 || %{}))
        |> Map.get("contents", [])

      assert is_map(preview_content)
      assert preview_content["content_text_truncated"] == true
      assert is_binary(preview_content["content_text"])
      assert String.length(preview_content["content_text"]) < String.length(long_text)

      assert is_map(chat_style_preview)

      assert chat_style_preview["content_json"] == %{
               "tool_call_id" => "call_chat",
               "name" => "reader__read_url"
             }

      assert is_map(responses_text_preview)
      assert responses_text_preview["content_text_truncated"] == true
      assert is_binary(responses_text_preview["content_text"])
      assert String.length(responses_text_preview["content_text"]) < String.length(long_text)

      assert is_map(responses_style_preview)

      assert responses_style_preview["content_json"] == %{
               "responses_item" => %{
                 "type" => "function_call_output",
                 "id" => "fco_123",
                 "call_id" => "call_resp"
               }
             }

      assert Enum.all?(reasoning_contents, fn content -> content["kind"] != "opaque" end)
      refute Enum.any?(reasoning_contents, fn content -> content["id"] == reasoning_opaque.id end)

      full =
        conn
        |> get(~p"/api/bff/chat-messages/#{assistant_message.id}/contents/#{content.id}/full")
        |> json_response(200)

      assert get_in(full, ["content", "content_text"]) == long_text
    end
  end

  describe "legacy routes" do
    test "removed chat BFF routes return 404", %{conn: conn} do
      assert conn |> get("/api/bff/chats") |> response(404)
      assert build_conn() |> get("/api/bff/chats/123/state") |> response(404)
    end
  end

  defp all_text_contents(message_payload) do
    message_payload
    |> get_in(["content", "parts"])
    |> List.wrap()
    |> Enum.map(fn part -> Map.get(part, "text") || "" end)
  end

  defp create_chat_message_step!(message_id, sequence, status, actor) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_id: message_id,
        sequence: sequence,
        status: status,
        raw_request: %{"messages" => []}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_chat_message_item!(step_id, sequence, type, actor) do
    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_step_id: step_id, sequence: sequence, type: type},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_chat_message_text_content!(item_id, sequence, text, actor) do
    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item_id,
        sequence: sequence,
        kind: :text,
        content_text: text
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_chat_message_opaque_content!(item_id, sequence, json, actor) do
    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item_id,
        sequence: sequence,
        kind: :opaque,
        content_json: json
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp text_content(message) do
    message
    |> get_in(["content", "parts"])
    |> List.wrap()
    |> Enum.map_join("\n", &to_string(&1["text"] || ""))
  end
end
