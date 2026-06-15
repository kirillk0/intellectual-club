defmodule IntellectualClubWeb.Bff.ChatHandoffTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.Previews
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.TokenCounter
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  defmodule ScriptedSSEPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, body, conn} = read_body(conn)

      payload =
        case Jason.decode(body) do
          {:ok, %{} = decoded} -> decoded
          _other -> %{"raw_body" => body}
        end

      {response_chunks, status_code} =
        Agent.get_and_update(agent, fn state ->
          request_path = conn.request_path

          requests =
            Map.update(state.requests, request_path, [payload], fn existing ->
              existing ++ [payload]
            end)

          case Map.get(state.scripts, request_path, []) do
            [{code, chunks} | rest] ->
              {{chunks, code},
               %{state | scripts: Map.put(state.scripts, request_path, rest), requests: requests}}

            [] ->
              {{"No scripted response for #{request_path}", 500}, %{state | requests: requests}}
          end
        end)

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(status_code)

      Enum.reduce_while(List.wrap(response_chunks), conn, fn chunk, conn ->
        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end
  end

  test "handoff service creates linked child chat and copies chat-level bindings" do
    %{user: actor} = user_fixture()

    source = create_chat!(actor, "Source chat")

    {:ok, source_message} =
      Threads.add_message_to_end(source, :user, "Current work", actor: actor)

    block = create_knowledge_block!(actor)
    tool = create_tool_instance!(actor)
    _block_binding = create_chat_block_binding!(actor, source, block)
    _tool_binding = create_chat_tool_binding!(actor, source, tool)

    assert {:ok, %{chat: target, message: summary_message, generation: nil}} =
             Handoff.create_handoff_chat(source, actor, "Continue from this summary.",
               source_message_id: source_message.id
             )

    assert target.parent_chat_id == source.id
    assert target.parent_message_id == source_message.id
    assert target.parent_relation_kind == :handoff
    assert target.last_message_id == summary_message.id

    messages = messages_for_chat!(target.id, actor)
    assert Enum.map(messages, & &1.id) == [summary_message.id]
    assert hd(messages).role == :user

    handoff_text = message_text(hd(messages))
    assert String.starts_with?(handoff_text, "Conversation continued")
    assert String.contains?(handoff_text, "<summary>Previous conversation</summary>")
    assert Regex.match?(~r/\*\*user\*\* \(\d{4}-\d{2}-\d{2} \d{2}:\d{2}Z\):/, handoff_text)
    refute Regex.match?(~r/\*\*user\*\* \(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/, handoff_text)
    assert String.contains?(handoff_text, "Current work")
    assert String.contains?(handoff_text, "<summary>Handoff message</summary>")
    assert String.contains?(handoff_text, "Continue from this summary.")

    child_ids =
      source
      |> Ash.load!(:child_chats, actor: actor)
      |> Map.get(:child_chats)
      |> Enum.map(& &1.id)

    assert target.id in child_ids

    assert [%ChatKnowledgeBlock{knowledge_block_id: block_id, enabled: false, sequence: 7}] =
             chat_block_bindings!(target.id, actor)

    assert block_id == block.id

    assert [%ChatToolBinding{tool_instance_id: tool_id, enabled: true, sequence: 3}] =
             chat_tool_bindings!(target.id, actor)

    assert tool_id == tool.id
  end

  test "POST /api/bff/chats/:id/handoff persists summary as assistant message and creates child chat",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    scripts = %{
      "/chat/completions" => [
        {200,
         sse_chunks([
           %{
             "id" => "chatcmpl-manual-handoff",
             "object" => "chat.completion",
             "created" => 1,
             "model" => "test-chat-model",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => "Manual handoff summary."
                 },
                 "finish_reason" => "stop"
               }
             ]
           }
         ])}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)
    configuration = create_llm_configuration!(actor, base_url)
    source = create_chat!(actor, "Manual source", llm_configuration_id: configuration.id)

    {:ok, source_message} =
      Threads.add_message_to_end(source, :user, "Summarize me", actor: actor)

    conn = post(conn, ~p"/api/bff/chats/#{source.id}/handoff", %{})
    payload = json_response(conn, 200)

    generation_message_id = payload["generation"]["message_id"]
    assert is_integer(generation_message_id)
    assert List.last(payload["branch"])["id"] == generation_message_id
    assert List.last(payload["branch"])["role"] == "assistant"
    assert Enum.at(payload["branch"], -2)["role"] == "user"

    generation_payload = wait_for_generation_to_finish(conn, generation_message_id)
    assert generation_payload["status"] == "done"

    [original_message, handoff_prompt_message, summary_message] =
      messages_for_chat!(source.id, actor)

    assert original_message.id == source_message.id
    assert handoff_prompt_message.parent_id == source_message.id
    assert handoff_prompt_message.role == :user
    assert handoff_prompt_message.status == :done

    assert String.contains?(
             message_text(handoff_prompt_message),
             "You are preparing a handoff summary"
           )

    assert summary_message.parent_id == handoff_prompt_message.id
    assert summary_message.role == :assistant
    assert summary_message.status == :done
    assert summary_message.id == generation_message_id
    assert message_text(summary_message) == "Manual handoff summary."

    source_conn =
      get(
        build_conn() |> sign_in_conn(actor.username, password),
        ~p"/api/bff/chats/#{source.id}/state"
      )

    source_payload = json_response(source_conn, 200)

    children =
      source_payload["relations"]["children_by_message_id"][
        Integer.to_string(generation_message_id)
      ]

    assert [%{"chat_id" => target_id, "kind" => "handoff"}] = children
    assert is_integer(target_id)

    target =
      Chat
      |> Ash.get!(target_id, actor: actor, load: [:last_message])

    assert target.parent_chat_id == source.id
    assert target.parent_message_id == generation_message_id
    assert target.parent_relation_kind == :handoff

    target_messages = messages_for_chat!(target_id, actor)
    assert length(target_messages) == 1
    assert hd(target_messages).role == :user
    assert hd(target_messages).status == :done

    target_text = message_text(hd(target_messages))
    assert String.starts_with?(target_text, "Conversation continued")
    assert String.contains?(target_text, "Summarize me")
    assert String.contains?(target_text, "Manual handoff summary.")
    refute String.contains?(target_text, "You are preparing a handoff summary")

    refute Enum.any?(target_messages, &(&1.status == :generating))
  end

  test "POST /api/bff/chats/:id/handoff rejects non-owner", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: other, password: password} = user_fixture()
    conn = sign_in_conn(conn, other.username, password)

    source = create_chat!(owner, "Private source")

    conn = post(conn, ~p"/api/bff/chats/#{source.id}/handoff", %{})
    assert response(conn, conn.status)
    assert conn.status in [403, 404]
  end

  test "manual handoff generation sends persisted summary prompt with chat system prefix",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    scripts = %{
      "/chat/completions" => [
        {200,
         sse_chunks([
           %{
             "id" => "chatcmpl-summary",
             "object" => "chat.completion",
             "created" => 1,
             "model" => "test-chat-model",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => "Summary from same prompt prefix."
                 },
                 "finish_reason" => "stop"
               }
             ]
           }
         ])}
      ]
    }

    {base_url, agent} = start_scripted_server!(scripts)
    configuration = create_llm_configuration!(actor, base_url)
    source = create_chat!(actor, "Manual source", llm_configuration_id: configuration.id)
    block = create_knowledge_block!(actor, "Chat prefix", "Chat system prefix content.")
    create_chat_block_binding!(actor, source, block, enabled: true)

    {:ok, _source_message} =
      Threads.add_message_to_end(source, :user, "Original user context", actor: actor)

    assert {:ok, context} = Handoff.manual_handoff(source.id, actor)
    generation_payload = wait_for_generation_to_finish(conn, context.message_id)
    assert generation_payload["status"] == "done"

    [_original_message, handoff_prompt_message, summary_message] =
      messages_for_chat!(source.id, actor)

    assert handoff_prompt_message.role == :user

    assert String.contains?(
             message_text(handoff_prompt_message),
             "You are preparing a handoff summary"
           )

    assert summary_message.parent_id == handoff_prompt_message.id
    assert summary_message.id == context.message_id
    assert message_text(summary_message) == "Summary from same prompt prefix."

    requests = Agent.get(agent, & &1.requests)
    [request] = Map.get(requests, "/chat/completions", [])
    messages = request["messages"]

    assert [%{"role" => "system", "content" => system_content} | rest] = messages
    assert String.contains?(system_content, "Chat system prefix content.")
    refute String.contains?(system_content, "You are preparing a handoff summary")

    assert Enum.at(rest, -2) == %{"role" => "user", "content" => "Original user context"}

    assert %{"role" => "user", "content" => summary_request} = List.last(rest)
    assert String.contains?(summary_request, "You are preparing a handoff summary")
    assert String.contains?(summary_request, "Create the handoff summary now.")

    refute Map.has_key?(request, "tools")
  end

  test "manual handoff uses bot handoff message block content as summary prompt", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    scripts = %{
      "/chat/completions" => [
        {200,
         sse_chunks([
           %{
             "id" => "chatcmpl-custom-handoff",
             "object" => "chat.completion",
             "created" => 1,
             "model" => "test-chat-model",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => "Summary from custom handoff prompt."
                 },
                 "finish_reason" => "stop"
               }
             ]
           }
         ])}
      ]
    }

    {base_url, agent} = start_scripted_server!(scripts)
    configuration = create_llm_configuration!(actor, base_url)

    handoff_block =
      create_knowledge_block!(
        actor,
        "Handoff block title",
        "Custom handoff prompt body.\nUse only the useful continuation state."
      )

    bot = create_bot!(actor, "Custom handoff bot", handoff_message_block_id: handoff_block.id)

    source =
      create_chat!(actor, "Manual source",
        bot_id: bot.id,
        llm_configuration_id: configuration.id
      )

    {:ok, _source_message} =
      Threads.add_message_to_end(source, :user, "Original user context", actor: actor)

    assert {:ok, context} = Handoff.manual_handoff(source.id, actor)
    generation_payload = wait_for_generation_to_finish(conn, context.message_id)
    assert generation_payload["status"] == "done"

    [_original_message, handoff_prompt_message, summary_message] =
      messages_for_chat!(source.id, actor)

    prompt_text = message_text(handoff_prompt_message)

    assert prompt_text == "Custom handoff prompt body.\nUse only the useful continuation state."
    refute String.contains?(prompt_text, "Handoff block title")
    refute String.contains?(prompt_text, "You are preparing a handoff summary")

    assert summary_message.parent_id == handoff_prompt_message.id
    assert summary_message.id == context.message_id
    assert message_text(summary_message) == "Summary from custom handoff prompt."

    requests = Agent.get(agent, & &1.requests)
    [request] = Map.get(requests, "/chat/completions", [])

    assert %{
             "role" => "user",
             "content" => "Custom handoff prompt body.\nUse only the useful continuation state."
           } = List.last(request["messages"])

    refute Enum.any?(request["messages"], fn message ->
             String.contains?(
               to_string(message["content"] || ""),
               "You are preparing a handoff summary"
             )
           end)
  end

  test "GET /api/bff/chats/:id/state includes parent and child handoff relations", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "State source")
    {:ok, source_message} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, %{chat: target}} =
      Handoff.create_handoff_chat(source, actor, "State summary",
        source_message_id: source_message.id
      )

    source_conn = get(conn, ~p"/api/bff/chats/#{source.id}/state")
    source_payload = json_response(source_conn, 200)

    children =
      source_payload["relations"]["children_by_message_id"][Integer.to_string(source_message.id)]

    assert [%{"chat_id" => child_id, "kind" => "handoff"}] = children
    assert child_id == target.id
    assert source_payload["relations"]["children_without_message"] == []

    target_conn =
      get(
        build_conn() |> sign_in_conn(actor.username, password),
        ~p"/api/bff/chats/#{target.id}/state"
      )

    target_payload = json_response(target_conn, 200)

    assert target_payload["relations"]["parent"]["chat_id"] == source.id
    assert target_payload["relations"]["parent"]["message_id"] == source_message.id
    assert target_payload["relations"]["parent"]["kind"] == "handoff"
  end

  test "GET /api/bff/chats includes relation hints", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "List source")
    {:ok, source_message} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, %{chat: target}} =
      Handoff.create_handoff_chat(source, actor, "List summary",
        source_message_id: source_message.id
      )

    conn = get(conn, ~p"/api/bff/chats")
    payload = json_response(conn, 200)

    source_summary = Enum.find(payload["chats"], &(&1["id"] == source.id))
    target_summary = Enum.find(payload["chats"], &(&1["id"] == target.id))

    assert source_summary["child_handoff_count"] == 1
    assert target_summary["parent_chat_id"] == source.id
    assert target_summary["parent_message_id"] == source_message.id
    assert target_summary["parent_relation_kind"] == "handoff"
  end

  test "nested handoff expands parent history and skips child summary root" do
    %{user: actor} = user_fixture()

    source = create_chat!(actor, "Nested source")
    {:ok, root} = Threads.add_message_to_end(source, :user, "Root task", actor: actor)

    {:ok, parent_answer} =
      Threads.add_message_to_end(source, :assistant, "Parent answer",
        actor: actor,
        parent_id: root.id
      )

    assert {:ok, %{chat: first_child}} =
             Handoff.create_handoff_chat(source, actor, "First handoff summary",
               source_message_id: parent_answer.id
             )

    {:ok, child_user} =
      Threads.add_message_to_end(first_child, :user, "Child follow-up", actor: actor)

    {:ok, child_answer} =
      Threads.add_message_to_end(first_child, :assistant, "Child answer",
        actor: actor,
        parent_id: child_user.id
      )

    assert {:ok, %{chat: second_child, message: first_message}} =
             Handoff.create_handoff_chat(first_child, actor, "Second handoff summary",
               source_message_id: child_answer.id
             )

    [message] = messages_for_chat!(second_child.id, actor)
    assert message.id == first_message.id

    text = message_text(message)
    assert String.contains?(text, "Root task")
    assert String.contains?(text, "<continued in new chat>")
    assert String.contains?(text, "Child follow-up")
    assert String.contains?(text, "Child answer")
    assert String.contains?(text, "Second handoff summary")
    refute String.contains?(text, "First handoff summary")
    refute String.contains?(text, "Parent answer")
  end

  test "handoff history preserves artifact file references in previous conversation" do
    %{user: actor} = user_fixture()

    source = create_chat!(actor, "Artifact source")
    {:ok, file} = Files.create_from_binary("report.md", "text/markdown", "# Report")

    {:ok, source_message} =
      Threads.add_message_to_end(source, :user, "",
        actor: actor,
        contents: [
          %{kind: :text, content_text: "See attached report."},
          %{kind: :media, file_id: file.id}
        ]
      )

    assert {:ok, %{chat: target}} =
             Handoff.create_handoff_chat(source, actor, "Continue with the report.",
               source_message_id: source_message.id
             )

    [message] = messages_for_chat!(target.id, actor)
    text = message_text(message)

    assert String.contains?(text, "See attached report.")
    assert String.contains?(text, "file_id=#{file.external_id}")
    assert String.contains?(text, "filename=\"report.md\"")
    assert String.contains?(text, "/api/bff/chat-messages/#{source_message.id}/contents/")
  end

  test "handoff truncates assistant history and attaches full conversation" do
    %{user: actor} = user_fixture()

    source = create_chat!(actor, "Assistant truncation source")
    {:ok, _user_message} = Threads.add_message_to_end(source, :user, "Short prompt", actor: actor)

    long_answer = String.duplicate("assistant-long-output ", 6_000)

    {:ok, assistant_message} =
      Threads.add_message_to_end(source, :assistant, long_answer, actor: actor)

    assert {:ok, %{chat: target}} =
             Handoff.create_handoff_chat(source, actor, "Continue after long answer.",
               source_message_id: assistant_message.id
             )

    [message] = messages_for_chat!(target.id, actor)
    text = message_text(message)

    assert String.contains?(text, "[truncated to 200 tokens]")
    assert String.contains?(text, "Continue after long answer.")

    [artifact_content] = media_contents_for_message!(message.id, actor)
    assert artifact_content.file.filename == "full_conversation.md"
    assert artifact_content.file.mime_type == "text/markdown"

    assert {:ok, {_file, payload}} = Files.load_payload(artifact_content.file_id)
    assert String.contains?(payload, "# Previous conversation")
    assert String.contains?(payload, "Short prompt")
    assert String.contains?(payload, "assistant-long-output")
    refute String.contains?(payload, "[truncated to 200 tokens]")
  end

  test "handoff renders assistant answer items as separate entries before truncating" do
    %{user: actor} = user_fixture()

    source = create_chat!(actor, "Assistant item source")
    {:ok, user_message} = Threads.add_message_to_end(source, :user, "Question", actor: actor)

    {:ok, assistant_message} =
      Threads.add_message_to_end(source, :assistant, "Short commentary.",
        actor: actor,
        parent_id: user_message.id
      )

    step = first_step!(assistant_message.id, actor)
    long_final = String.duplicate("long-final-output ", 6_000)
    create_answer_item!(step.id, 2, long_final, actor)

    assert {:ok, %{chat: target}} =
             Handoff.create_handoff_chat(source, actor, "Continue after mixed assistant output.",
               source_message_id: assistant_message.id
             )

    [message] = messages_for_chat!(target.id, actor)
    text = message_text(message)

    assert Regex.scan(~r/\*\*assistant\*\* \(/, text) |> length() == 2
    assert String.contains?(text, "Short commentary.")
    assert String.contains?(text, "[truncated to 200 tokens]")

    assert String.contains?(
             text,
             "**assistant** (#{timestamp_minute_text(assistant_message.created_at)}):\nShort commentary.\n"
           )

    assert String.contains?(text, "Continue after mixed assistant output.")
  end

  test "handoff hard middle-out attaches full conversation when compact history is still too large" do
    %{user: actor} = user_fixture()

    source = create_chat!(actor, "Massive source")

    last_message =
      Enum.reduce(1..130, nil, fn idx, _last ->
        marker = idx |> Integer.to_string() |> String.pad_leading(3, "0")
        text = "message-#{marker} " <> String.duplicate("wide-context ", 90)
        {:ok, message} = Threads.add_message_to_end(source, :user, text, actor: actor)
        message
      end)

    assert {:ok, %{chat: target, message: target_message}} =
             Handoff.create_handoff_chat(source, actor, "Continue massive work.",
               source_message_id: last_message.id
             )

    [loaded_target_message] = messages_for_chat!(target.id, actor)
    text = message_text(loaded_target_message)

    assert TokenCounter.estimate(text) <= 20_000
    assert String.contains?(text, "message-001")
    assert String.contains?(text, "message-130")
    assert String.contains?(text, "omitted")
    assert String.contains?(text, "full_conversation.md")

    [artifact_content] = media_contents_for_message!(target_message.id, actor)
    assert artifact_content.file.filename == "full_conversation.md"
    assert artifact_content.file.mime_type == "text/markdown"

    assert target.last_message_id == target_message.id
  end

  defp create_chat!(actor, _title, attrs \\ []) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      attrs
      |> Map.new()
      |> Map.merge(%{note: ""}),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_knowledge_block!(actor, name \\ "Block", content \\ "Knowledge") do
    KnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, version: "v1", content: content},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_bot!(actor, name, attrs) do
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

  defp create_llm_configuration!(actor, base_url) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Handoff summary provider",
          type: :openrouter_chat_completion,
          auth_method: :api_key,
          base_url: base_url,
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!()

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "test-model",
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

  defp create_chat_block_binding!(actor, chat, block, opts \\ []) do
    ChatKnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_id: chat.id,
        knowledge_block_id: block.id,
        enabled: Keyword.get(opts, :enabled, false),
        sequence: Keyword.get(opts, :sequence, 7)
      },
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

  defp messages_for_chat!(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(steps: [items: [:contents]])
    |> Ash.read!(actor: actor)
  end

  defp media_contents_for_message!(message_id, actor) do
    ChatMessageContent
    |> Ash.Query.filter(
      kind == :media and
        chat_message_item.chat_message_step.chat_message_id == ^message_id
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:file)
    |> Ash.read!(actor: actor)
  end

  defp first_step!(message_id, actor) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^message_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: actor)
  end

  defp create_answer_item!(step_id, sequence, text, actor) do
    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step_id, sequence: sequence, type: :answer},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :text,
        content_text: text
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    item
  end

  defp timestamp_minute_text(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%MZ")
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
    Previews.message_preview_text(message)
  end

  defp start_scripted_server!(scripts) when is_map(scripts) do
    {:ok, agent} =
      start_supervised(
        {Agent,
         fn ->
           %{
             scripts: scripts,
             requests: %{}
           }
         end}
      )

    port = free_port()

    {:ok, _server} =
      start_supervised({Bandit, plug: {ScriptedSSEPlug, agent: agent}, scheme: :http, port: port})

    {"http://127.0.0.1:#{port}", agent}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp sse_chunks(objects) when is_list(objects) do
    Enum.map(objects, fn object -> "data: " <> Jason.encode!(object) <> "\n\n" end) ++
      ["data: [DONE]\n\n"]
  end
end
