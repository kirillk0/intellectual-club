defmodule IntellectualClubWeb.Bff.ChatExportTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotShare
  alias IntellectualClub.Files
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockFile
  alias IntellectualClub.Knowledge.KnowledgeBlockTag
  alias IntellectualClub.Knowledge.KnowledgeTag
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationShare
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance

  test "export started from a child returns the related family and active branches", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    root = create_chat!(actor, "Root")
    {:ok, root_message} = Threads.add_message_to_end(root, :user, "Question", actor: actor)

    {:ok, inactive} =
      Threads.add_message(root, :assistant, "Inactive alternative",
        actor: actor,
        parent_id: root_message.id
      )

    {:ok, active} =
      Threads.add_message(root, :assistant, "Active answer",
        actor: actor,
        parent_id: root_message.id
      )

    {:ok, _branch} = Threads.activate_branch(root.id, active.id, actor)

    child =
      create_chat!(actor, "Fork", %{
        parent_chat_id: root.id,
        parent_message_id: active.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    {:ok, child_message} =
      Threads.add_message_to_end(child, :user, "Child question", actor: actor)

    grandchild =
      create_chat!(actor, "Spawn", %{
        parent_chat_id: child.id,
        parent_message_id: child_message.id,
        parent_relation_kind: :spawn,
        subagent: true
      })

    {:ok, _grandchild_message} =
      Threads.add_message_to_end(grandchild, :assistant, "Child answer", actor: actor)

    handoff =
      create_chat!(actor, "Handoff", %{
        parent_chat_id: root.id,
        parent_message_id: active.id,
        parent_relation_kind: :handoff,
        subagent: true
      })

    inactive_child =
      create_chat!(actor, "Inactive fork", %{
        parent_chat_id: root.id,
        parent_message_id: inactive.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    {:ok, _inactive_child_message} =
      Threads.add_message_to_end(inactive_child, :assistant, "Hidden child", actor: actor)

    independent = create_chat!(actor, "Independent")

    payload =
      conn
      |> get(~p"/api/bff/chat-state/#{child.id}/export")
      |> json_response(200)

    assert payload["schema_version"] == 1
    assert payload["selected_chat_id"] == child.id
    assert payload["root_chat_id"] == root.id

    assert Enum.map(payload["chats"], & &1["id"]) == [
             root.id,
             child.id,
             handoff.id,
             grandchild.id
           ]

    refute independent.id in Enum.map(payload["chats"], & &1["id"])
    refute inactive_child.id in Enum.map(payload["chats"], & &1["id"])

    root_payload = Enum.find(payload["chats"], &(&1["id"] == root.id))
    root_message_ids = Enum.map(root_payload["messages"], & &1["id"])
    assert root_message_ids == [root_message.id, active.id]
    refute inactive.id in root_message_ids

    child_payload = Enum.find(payload["chats"], &(&1["id"] == child.id))

    assert child_payload["relation"] == %{
             "kind" => "fork",
             "parent_chat_id" => root.id,
             "parent_message_id" => active.id
           }

    grandchild_payload = Enum.find(payload["chats"], &(&1["id"] == grandchild.id))
    assert grandchild_payload["relation"]["kind"] == "spawn"
    assert grandchild_payload["relation"]["parent_chat_id"] == child.id

    handoff_payload = Enum.find(payload["chats"], &(&1["id"] == handoff.id))
    assert handoff_payload["relation"]["kind"] == "handoff"

    inactive_payload =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chat-state/#{inactive_child.id}/export")
      |> json_response(200)

    assert inactive_payload["root_chat_id"] == inactive_child.id
    assert Enum.map(inactive_payload["chats"], & &1["id"]) == [inactive_child.id]
  end

  test "export projects working steps, resources, and attachments without private data", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Safe export")
    {:ok, attached_file} = Files.create_from_binary("brief.txt", "text/plain", "FILE_SECRET")

    {:ok, user_message} =
      Threads.add_message(chat, :user, "Read this",
        actor: actor,
        parent_id: nil,
        contents: [
          %{kind: :text, content_text: "Read this"},
          %{kind: :media, file_id: attached_file.id}
        ]
      )

    {:ok, assistant_message} =
      Threads.add_message(chat, :assistant, "Visible answer",
        actor: actor,
        parent_id: user_message.id
      )

    first_step = first_step!(assistant_message.id, actor)
    reasoning = create_item!(first_step.id, 20, :reasoning, actor)
    _reasoning_content = create_text_content!(reasoning.id, 1, "Visible reasoning", actor)

    tool_call = create_item!(first_step.id, 21, :tool_call, actor)

    _tool_call_content =
      create_opaque_content!(
        tool_call.id,
        1,
        %{
          "name" => "lookup",
          "arguments" => %{"query" => "public query"},
          "raw" => %{"provider_secret" => "RAW_TOOL_SECRET"}
        },
        actor
      )

    tool_result = create_item!(first_step.id, 22, :tool_result, actor, tool_call.id)
    long_result = Enum.map_join(1..8, "\n", &"line #{&1} #{String.duplicate("x", 120)}")
    _tool_result_content = create_text_content!(tool_result.id, 1, long_result, actor)

    second_step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: assistant_message.id,
          sequence: 2,
          status: :error,
          raw_request: %{"authorization" => "RAW_REQUEST_SECRET"},
          raw_response: %{"provider" => "RAW_RESPONSE_SECRET"},
          input_tokens: 9,
          output_tokens: 3,
          cost: 0.25
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    error_item = create_item!(second_step.id, 1, :error, actor)
    _error_content = create_text_content!(error_item.id, 1, "Retry failed", actor)

    tag =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Manuals"}, actor: actor)
      |> Ash.create!(actor: actor)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Instructions", version: "v7", content: "Full block text"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _tag_binding =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, knowledge_tag_id: tag.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, block_file} =
      Files.create_from_binary("manual.pdf", "application/pdf", "BLOCK_FILE_SECRET")

    _block_file_binding =
      KnowledgeBlockFile
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, file_id: block_file.id, sequence: 0, enabled: true},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _block_binding =
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, knowledge_block_id: block.id, enabled: true, sequence: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-agent-management",
          name: "Agent management",
          description: "Visible tool description",
          alias: "agents",
          config: %{"private" => "TOOL_CONFIG_SECRET"},
          secrets: %{"api_key" => "TOOL_SECRET"},
          max_output_tokens: 20_000
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _tool_binding =
      ChatToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, tool_instance_id: tool.id, enabled: true, sequence: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    payload =
      conn
      |> get(~p"/api/bff/chat-state/#{chat.id}/export")
      |> json_response(200)

    [chat_payload] = payload["chats"]
    assert Enum.map(chat_payload["context"]["blocks"], & &1["block_id"]) == [block.id]
    assert Enum.map(chat_payload["library"]["blocks"], & &1["block_id"]) == [block.id]
    assistant_payload = Enum.find(chat_payload["messages"], &(&1["id"] == assistant_message.id))
    assert Enum.map(assistant_payload["working_steps"], & &1["sequence"]) == [1, 2]
    assert get_in(assistant_payload, ["working_steps", Access.at(1), "status"]) == "error"
    assert get_in(assistant_payload, ["working_steps", Access.at(1), "input_tokens"]) == 9

    working_items =
      assistant_payload["working_steps"]
      |> Enum.flat_map(& &1["items"])

    assert Enum.any?(
             working_items,
             &(&1["type"] == "reasoning" and &1["text"] == "Visible reasoning")
           )

    call_payload = Enum.find(working_items, &(&1["type"] == "tool_call"))
    assert call_payload["name"] == "lookup"
    assert call_payload["arguments"] == %{"query" => "public query"}

    result_payload = Enum.find(working_items, &(&1["type"] == "tool_result"))
    assert result_payload["truncated"] == true
    assert String.length(result_payload["text"]) <= 604
    assert result_payload["text"] |> String.split("\n") |> length() <= 6
    refute String.contains?(result_payload["text"], "line 8")

    user_payload = Enum.find(chat_payload["messages"], &(&1["id"] == user_message.id))
    assert user_payload["working_steps"] == []
    [attachment] = get_in(user_payload, ["content", Access.at(0), "attachments"])

    assert attachment == %{
             "enabled" => true,
             "kind" => "file",
             "mime_type" => "text/plain",
             "name" => "brief.txt",
             "size_bytes" => byte_size("FILE_SECRET")
           }

    assert length(payload["resources"]["knowledge_blocks"]) == 1
    [block_payload] = payload["resources"]["knowledge_blocks"]
    assert block_payload["content"] == "Full block text"
    assert block_payload["version"] == "v7"
    assert block_payload["tags"] == ["Manuals"]

    assert [%{"name" => "manual.pdf", "mime_type" => "application/pdf"}] =
             Enum.map(block_payload["attachments"], &Map.take(&1, ["name", "mime_type"]))

    assert length(payload["resources"]["tools"]) == 1
    [tool_payload] = payload["resources"]["tools"]
    assert tool_payload["alias"] == "agents"
    assert tool_payload["description"] == "Visible tool description"

    assert Enum.all?(
             tool_payload["functions"],
             &(Map.keys(&1) |> Enum.sort() == ["description", "name"])
           )

    encoded = Jason.encode!(payload)

    for forbidden <- [
          "raw_request",
          "raw_response",
          "RAW_REQUEST_SECRET",
          "RAW_RESPONSE_SECRET",
          "RAW_TOOL_SECRET",
          "TOOL_CONFIG_SECRET",
          "TOOL_SECRET",
          "FILE_SECRET",
          "BLOCK_FILE_SECRET",
          attached_file.external_id,
          block_file.external_id,
          "sha256",
          "file_id",
          "url"
        ] do
      refute String.contains?(encoded, forbidden)
    end
  end

  test "export is owner-only and rejects shared read-only access", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: other, password: password} = user_fixture()
    chat = create_chat!(owner, "Private")

    response =
      conn
      |> sign_in_conn(other.username, password)
      |> get(~p"/api/bff/chat-state/#{chat.id}/export")

    assert response.status in [403, 404]
  end

  test "lineage ascent stops when a former parent is no longer accessible", %{conn: conn} do
    %{user: owner, password: owner_password} = user_fixture()
    %{user: actor, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, actor]})
    bot = create_bot!(owner)
    configuration = create_configuration!(owner)
    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)

    parent =
      create_chat!(owner, "Former parent", %{
        bot_id: bot.id,
        llm_configuration_id: configuration.id
      })

    owner_conn = sign_in_conn(conn, owner.username, owner_password)

    owner_conn
    |> put(~p"/api/bff/chat-shares/#{parent.id}", %{group_ids: [group.id]})
    |> json_response(200)

    child =
      create_chat!(actor, "Owned child", %{
        parent_chat_id: parent.id,
        parent_relation_kind: :fork
      })

    owner_conn
    |> recycle()
    |> sign_in_conn(owner.username, owner_password)
    |> put(~p"/api/bff/chat-shares/#{parent.id}", %{group_ids: []})
    |> json_response(200)

    payload =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chat-state/#{child.id}/export")
      |> json_response(200)

    assert payload["root_chat_id"] == child.id
    assert Enum.map(payload["chats"], & &1["id"]) == [child.id]
    assert hd(payload["chats"])["relation"] == nil
  end

  test "cyclic relation metadata does not repeat chats indefinitely", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    first = create_chat!(actor, "First")

    second =
      create_chat!(actor, "Second", %{
        parent_chat_id: first.id,
        parent_relation_kind: :handoff
      })

    _updated =
      first
      |> Ash.Changeset.for_update(
        :update,
        %{parent_chat_id: second.id, parent_relation_kind: :fork},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    payload =
      conn
      |> get(~p"/api/bff/chat-state/#{first.id}/export")
      |> json_response(200)

    assert Enum.map(payload["chats"], & &1["id"]) |> Enum.sort() ==
             Enum.sort([first.id, second.id])
  end

  defp create_chat!(actor, note, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      attrs |> Map.new() |> Map.put(:note, note),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp first_step!(message_id, actor) do
    ChatMessage
    |> Ash.get!(message_id, actor: actor, load: [steps: [:id, :sequence]])
    |> Map.fetch!(:steps)
    |> Enum.min_by(& &1.sequence)
  end

  defp create_item!(step_id, sequence, type, actor, tool_call_item_id \\ nil) do
    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_step_id: step_id,
        sequence: sequence,
        type: type,
        tool_call_item_id: tool_call_item_id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_text_content!(item_id, sequence, text, actor) do
    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_item_id: item_id, sequence: sequence, kind: :text, content_text: text},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_opaque_content!(item_id, sequence, json, actor) do
    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_item_id: item_id, sequence: sequence, kind: :opaque, content_json: json},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_bot!(actor) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Export parent bot", first_messages: [], history_mode: :chat},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration!(actor) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Export parent provider", type: :demo, auth_method: :api_key},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "demo-model",
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        context_length: 2048
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(:create, %{bot_id: bot.id, user_group_id: group.id}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp share_configuration!(actor, configuration, group) do
    LlmConfigurationShare
    |> Ash.Changeset.for_create(
      :create,
      %{llm_configuration_id: configuration.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
