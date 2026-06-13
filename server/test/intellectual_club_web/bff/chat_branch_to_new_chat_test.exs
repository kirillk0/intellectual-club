defmodule IntellectualClubWeb.Bff.ChatBranchToNewChatTest do
  @moduledoc """
  Branch-to-new-chat endpoint regression tests.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  test "POST /api/bff/chats/:id/branch-to-new-chat branches from assistant as alternative answer",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_bot!(actor, "Assistant branch bot")
    configuration = create_demo_configuration!(actor)

    source =
      create_chat!(actor, "Assistant source",
        note: "source note",
        bot_id: bot.id,
        llm_configuration_id: configuration.id
      )

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root prompt", actor: actor)

    {:ok, selected_assistant} =
      Threads.add_message_to_end(source, :assistant, "Selected answer", actor: actor)

    {:ok, inactive_assistant} =
      Threads.add_message(source, :assistant, "Inactive answer",
        actor: actor,
        parent_id: root.id
      )

    {:ok, _meta} = Threads.activate_branch(source.id, selected_assistant.id, actor)

    conn =
      post(conn, ~p"/api/bff/chats/#{source.id}/branch-to-new-chat", %{
        "message_id" => selected_assistant.id
      })

    payload = json_response(conn, 200)
    target_id = get_in(payload, ["chat", "id"])
    generation_id = get_in(payload, ["generation", "message_id"])

    assert is_integer(target_id)
    assert is_integer(generation_id)
    assert target_id != source.id

    assert get_in(payload, ["chat", "title"]) == "Assistant source"
    assert get_in(payload, ["chat", "note"]) == "source note (branch)"
    assert get_in(payload, ["chat", "bot_id"]) == bot.id
    assert get_in(payload, ["chat", "llm_configuration_id"]) == configuration.id

    target = Ash.get!(Chat, target_id, actor: actor)
    assert target.parent_chat_id == nil
    assert target.parent_message_id == nil
    assert target.parent_relation_kind == nil

    branch = payload["branch"] || []
    assert Enum.map(branch, & &1["role"]) == ["user", "assistant"]
    assert Enum.map(branch, & &1["id"]) == [List.first(branch)["id"], generation_id]
    assert Enum.at(branch, 1)["parent_id"] == List.first(branch)["id"]

    target_messages = messages_for_chat!(target_id, actor)
    target_text = Enum.map(target_messages, &message_text/1)

    assert "Root prompt" in target_text
    refute "Selected answer" in target_text
    refute "Inactive answer" in target_text
    refute Enum.any?(target_messages, &(&1.id == inactive_assistant.id))

    wait_for_generation_to_finish(conn, generation_id)
  end

  test "POST /api/bff/chats/:id/branch-to-new-chat branches from user with settings and attachments",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_artifact_bot!(actor, "User branch bot")
    source = create_chat!(actor, "User source", bot_id: bot.id)
    block = create_knowledge_block!(actor)
    tool = create_tool_instance!(actor)
    _block_binding = create_chat_block_binding!(actor, source, block)
    _tool_binding = create_chat_tool_binding!(actor, source, tool)

    {:ok, _root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)
    {:ok, assistant} = Threads.add_message_to_end(source, :assistant, "Answer", actor: actor)
    {:ok, copied_file} = Files.create_from_binary("copied.txt", "text/plain", "copied payload")

    {:ok, selected_user} =
      Threads.add_message(source, :user, "",
        actor: actor,
        parent_id: assistant.id,
        contents: [
          %{kind: :text, content_text: "Original follow-up"},
          %{kind: :media, file_id: copied_file.id}
        ]
      )

    {:ok, tail} = Threads.add_message_to_end(source, :assistant, "Tail answer", actor: actor)

    {:ok, _inactive_user} =
      Threads.add_message(source, :user, "Inactive follow-up",
        actor: actor,
        parent_id: assistant.id
      )

    {:ok, _meta} = Threads.activate_branch(source.id, tail.id, actor)

    copied_content_id = media_content_id!(selected_user.id, actor)
    upload = create_upload!(conn, source.id, "uploaded.txt", "text/plain", 16)
    upload_id = upload["upload_id"]

    build_conn()
    |> sign_in_conn(actor.username, password)
    |> upload_chunk!(source.id, upload_id, "uploaded payload")

    conn =
      post(conn, ~p"/api/bff/chats/#{source.id}/branch-to-new-chat", %{
        "message_id" => selected_user.id,
        "content" => "Replacement follow-up",
        "copy_content_ids" => [copied_content_id],
        "upload_ids" => [upload_id]
      })

    payload = json_response(conn, 200)
    target_id = get_in(payload, ["chat", "id"])
    generation_id = get_in(payload, ["generation", "message_id"])

    assert is_integer(target_id)
    assert is_integer(generation_id)

    branch = payload["branch"] || []
    replacement = Enum.at(branch, -2)
    generated = List.last(branch)

    assert Enum.map(branch, & &1["role"]) == ["user", "assistant", "user", "assistant"]
    assert all_text_contents(Enum.at(branch, 0)) == ["Root"]
    assert all_text_contents(Enum.at(branch, 1)) == ["Answer"]
    assert all_text_contents(replacement) == ["Replacement follow-up"]
    assert generated["id"] == generation_id
    assert generated["parent_id"] == replacement["id"]

    media = media_contents(replacement)
    assert length(media) == 2

    assert Enum.map(media, &get_in(&1, ["media", "filename"])) |> Enum.sort() == [
             "copied.txt",
             "uploaded.txt"
           ]

    target_messages = messages_for_chat!(target_id, actor)
    target_text = Enum.map(target_messages, &message_text/1)

    refute "Original follow-up" in target_text
    refute "Inactive follow-up" in target_text
    refute "Tail answer" in target_text

    assert [%ChatKnowledgeBlock{knowledge_block_id: block_id, enabled: false, sequence: 7}] =
             chat_block_bindings!(target_id, actor)

    assert block_id == block.id

    assert [%ChatToolBinding{tool_instance_id: tool_id, enabled: true, sequence: 3}] =
             chat_tool_bindings!(target_id, actor)

    assert tool_id == tool.id

    wait_for_generation_to_finish(conn, generation_id)
  end

  test "POST /api/bff/chats/:id/branch-to-new-chat rejects missing message id", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor, "Missing message id")

    conn = post(conn, ~p"/api/bff/chats/#{source.id}/branch-to-new-chat", %{})
    payload = json_response(conn, 422)

    assert payload["error"] == "message_id is required"
  end

  test "POST /api/bff/chats/:id/branch-to-new-chat rejects inactive message", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor, "Inactive message")

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, active} =
      Threads.add_message(source, :assistant, "Active", actor: actor, parent_id: root.id)

    {:ok, inactive} =
      Threads.add_message(source, :assistant, "Inactive", actor: actor, parent_id: root.id)

    {:ok, _meta} = Threads.activate_branch(source.id, active.id, actor)

    conn =
      post(conn, ~p"/api/bff/chats/#{source.id}/branch-to-new-chat", %{
        "message_id" => inactive.id
      })

    payload = json_response(conn, 422)
    assert payload["error"] == "Message is not in the active branch."
  end

  test "POST /api/bff/chats/:id/branch-to-new-chat rejects non-owner", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: other, password: password} = user_fixture()
    conn = sign_in_conn(conn, other.username, password)

    source = create_chat!(owner, "Private source")
    {:ok, message} = Threads.add_message_to_end(source, :user, "Root", actor: owner)

    conn =
      post(conn, ~p"/api/bff/chats/#{source.id}/branch-to-new-chat", %{
        "message_id" => message.id,
        "content" => "Replacement"
      })

    assert response(conn, conn.status)
    assert conn.status in [403, 404]
  end

  defp create_chat!(actor, title, attrs \\ []) do
    attrs = Map.new(attrs)

    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        title: title,
        note: ""
      }
      |> Map.merge(attrs),
      actor: actor
    )
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

  defp create_artifact_bot!(actor, name) do
    bot = create_bot!(actor, name, max_file_size_bytes: 500 * 1024 * 1024)
    tool = create_artifact_tool!(actor, "#{name} Artifact Reader")
    bind_tool_to_bot!(actor, bot, tool)
    bot
  end

  defp create_artifact_tool!(actor, name) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-artifact-reader",
        name: name,
        alias: "artifacts",
        config: %{},
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp bind_tool_to_bot!(actor, bot, tool) do
    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: tool.id,
        sharing_mode: :shared,
        enabled: true,
        sequence: 0
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_demo_configuration!(actor) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Branch demo provider", type: :demo, auth_method: :api_key},
        actor: actor
      )
      |> Ash.create!()

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "demo",
        parameters: %{},
        enabled: true,
        timeout_seconds: 5,
        supports_cache_control: false,
        supports_image_input: false
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_knowledge_block!(actor) do
    KnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Branch block", version: "v1", content: "Knowledge"},
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

  defp create_upload!(conn, chat_id, filename, mime_type, size_bytes) do
    conn =
      post(conn, ~p"/api/bff/chats/#{chat_id}/uploads", %{
        "filename" => filename,
        "mime_type" => mime_type,
        "size_bytes" => size_bytes
      })

    json_response(conn, 200)["upload"]
  end

  defp upload_chunk!(conn, chat_id, upload_id, payload) do
    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-upload-offset", "0")
      |> put(~p"/api/bff/chats/#{chat_id}/uploads/#{upload_id}/chunk", payload)

    json_response(conn, 200)
  end

  defp messages_for_chat!(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(steps: [items: [:contents]])
    |> Ash.read!(actor: actor)
  end

  defp media_content_id!(message_id, actor) do
    message =
      ChatMessage
      |> Ash.get!(message_id, actor: actor, load: [steps: [items: [:contents]]])

    message.steps
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.flat_map(&(&1.contents || []))
    |> Enum.find_value(fn content ->
      if content.kind == :media, do: content.id, else: nil
    end)
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

  defp message_text(%ChatMessage{} = message) do
    IntellectualClub.Chat.Previews.message_preview_text(message)
  end

  defp all_text_contents(message) when is_map(message) do
    message
    |> Map.get("content", %{})
    |> Map.get("parts", [])
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.reject(&is_nil/1)
  end

  defp media_contents(message) when is_map(message) do
    message
    |> Map.get("content", %{})
    |> Map.get("media", [])
  end
end
