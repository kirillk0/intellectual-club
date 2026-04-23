defmodule IntellectualClubWeb.Bff.ChatStateTest do
  @moduledoc """
  BFF state endpoint tests for the SPA.

  These tests validate that the server returns the datasets required by the SPA
  without going through LiveView assigns.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationTag}
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance

  test "GET /api/bff/chats/:id/state returns trace for markdown user message", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{title: "Markdown chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    markdown = """
    # Title

    Hello **world**.
    """

    {:ok, _message} = Threads.add_message_to_end(chat, :user, markdown, actor: actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
    payload = json_response(conn, 200)

    branch = Map.get(payload, "branch", [])
    assert is_list(branch)
    assert length(branch) >= 1

    first = List.first(branch)
    texts = all_text_contents(first)
    assert Enum.any?(texts, &String.contains?(&1, "# Title"))
    assert Enum.any?(texts, &String.contains?(&1, "**world**"))
  end

  test "GET /api/bff/chats/:id/state includes nested steps/items/contents", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Answer preview chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    long_text = String.duplicate("A", 220) <> "TAIL"

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hi", actor: actor)

    {:ok, assistant_message} =
      Threads.add_message(chat, :assistant, long_text, actor: actor, parent_id: user_message.id)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
    payload = json_response(conn, 200)

    branch = Map.get(payload, "branch", [])

    assistant =
      Enum.find(branch, fn message ->
        message["id"] == assistant_message.id
      end)

    assert is_map(assistant)
    assert is_binary(assistant["finished_at"])
    assert is_binary(get_in(assistant, ["steps", Access.at(0), "finished_at"]))

    assert Enum.any?(all_text_contents(assistant), &String.contains?(&1, "TAIL"))
  end

  test "GET /api/bff/chats/:id/state includes context settings in options", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "Provider A")
    config = create_configuration!(actor, provider, "model-x", 8192)
    bot = create_bot!(actor, "Agent bot", 75)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "State options chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
    payload = json_response(conn, 200)

    bots = get_in(payload, ["options", "bots"]) || []
    llm_configs = get_in(payload, ["options", "llm_configurations"]) || []

    bot_payload = Enum.find(bots, fn item -> item["id"] == bot.id end) || %{}
    cfg_payload = Enum.find(llm_configs, fn item -> item["id"] == config.id end) || %{}

    assert bot_payload["context_soft_limit_percent"] == 75
    assert is_binary(bot_payload["created_at"])
    assert is_binary(bot_payload["updated_at"])
    assert bot_payload["sort_activity_at"] == bot_payload["updated_at"]
    assert cfg_payload["context_length"] == 8192
  end

  test "GET /api/bff/chats/:id/state includes configuration and bot tag metadata in options", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    tag =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Compatible"}, actor: actor)
      |> Ash.create!(actor: actor)

    provider = create_provider!(actor, "Provider tags")

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
          title: "Tagged state chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    payload =
      conn
      |> get(~p"/api/bff/chats/#{chat.id}/state")
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

  test "GET /api/bff/chats/:id/state includes user prompt sources", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    user_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "User setting block", version: "v1", type: :lore, content: "always include me"},
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
      |> Ash.Changeset.for_create(:create, %{title: "User source chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
    payload = json_response(conn, 200)

    user_sources = get_in(payload, ["prompt_sources", "user"]) || []
    assert length(user_sources) == 1

    [first_source] = user_sources
    assert get_in(first_source, ["knowledge_block", "id"]) == user_block.id
  end

  test "GET /api/bff/chats/:id/state orders configuration top blocks before bot blocks", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    top_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config top", version: "v1", type: :rules, content: "config-top"},
        actor: actor
      )
      |> Ash.create!()

    bot_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Bot block", version: "v1", type: :lore, content: "bot"},
        actor: actor
      )
      |> Ash.create!()

    bottom_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config bottom", version: "v1", type: :rules, content: "config-bottom"},
        actor: actor
      )
      |> Ash.create!()

    bot = create_bot!(actor, "Prompt bot", 80)
    provider = create_provider!(actor, "Provider A")
    config = create_configuration!(actor, provider, "model-top", 8192)

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
          title: "Prompt state chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
    payload = json_response(conn, 200)

    assert Regex.match?(
             ~r/# Config top.*# Bot block.*# Config bottom/s,
             payload["compiled_prompt_text"] || ""
           )

    assert Enum.map(get_in(payload, ["prompt_sources", "configuration"]) || [], & &1["selection"]) ==
             [
               "top",
               "bottom"
             ]
  end

  test "GET /api/bff/chats/:id/state includes image metadata in bot and knowledge block options",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    assert {:ok, bot_file} =
             Files.create_from_upload(%{
               filename: "bot.png",
               mime_type: "image/png",
               payload: image_payload()
             })

    assert {:ok, block_file} =
             Files.create_from_upload(%{
               filename: "block.png",
               mime_type: "image/png",
               payload: image_payload()
             })

    bot =
      create_bot!(actor, "Image bot", 80)
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
        %{name: "Image block", version: "v1", type: :rules, content: "content"},
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
        %{title: "Image options chat", note: "", bot_id: bot.id, variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/state")
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

  test "GET /api/bff/chats/:id/state includes chat tool bindings and resolved active tools", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_bot!(actor, "Tool bot", 80)

    base_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp_http",
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
          type: "mcp_http",
          name: "Chat tool",
          config: %{"server_url" => "https://example.com/chat"},
          secrets: %{"bearer_token" => "chat"}
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
          alias: "web",
          sharing_mode: :per_user,
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
        %{title: "Chat tool state", note: "", bot_id: bot.id, variables: %{}},
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
          alias: "web",
          enabled: true,
          sequence: 0
        },
        actor: actor
      )
      |> Ash.create!()

    payload =
      conn
      |> get(~p"/api/bff/chats/#{chat.id}/state")
      |> json_response(200)

    assert get_in(payload, ["missing_required_per_user_tool_aliases"]) == []

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

  test "GET /api/bff/chats/:id/prompt-context returns only prompt-related payload", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config prompt block", version: "v1", type: :rules, content: "config prompt"},
        actor: actor
      )
      |> Ash.create!()

    provider = create_provider!(actor, "Prompt Provider")
    config = create_configuration!(actor, provider, "prompt-model", 4096)

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
          title: "Prompt context chat",
          note: "",
          llm_configuration_id: config.id,
          variables: %{"topic" => "astronomy"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    payload =
      conn
      |> get(~p"/api/bff/chats/#{chat.id}/prompt-context")
      |> json_response(200)

    assert get_in(payload, [
             "prompt_sources",
             "configuration",
             Access.at(0),
             "knowledge_block",
             "id"
           ]) ==
             block.id

    assert is_binary(payload["compiled_prompt_text"])
    assert String.contains?(payload["compiled_prompt_text"], "config prompt")
    assert payload["counters"]["history_message_count"] == 1
    refute Map.has_key?(payload, "branch")
    refute Map.has_key?(payload, "options")
  end

  defp all_text_contents(message_payload) do
    (Map.get(message_payload, "steps") || [])
    |> Enum.flat_map(fn step -> Map.get(step, "items") || [] end)
    |> Enum.flat_map(fn item -> Map.get(item, "contents") || [] end)
    |> Enum.filter(fn content -> Map.get(content, "kind") == "text" end)
    |> Enum.map(fn content -> Map.get(content, "content_text") || "" end)
  end

  defp create_bot!(actor, name, context_soft_limit_percent) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        variables: %{},
        max_tool_rounds: 20,
        context_soft_limit_percent: context_soft_limit_percent
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

  defp create_configuration!(actor, provider, model_name, context_length) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: model_name,
        note: "cfg",
        parameters: %{},
        context_length: context_length,
        enabled: true,
        timeout_seconds: 300
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
