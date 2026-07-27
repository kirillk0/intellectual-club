defmodule IntellectualClubWeb.Bff.ChatHandoffTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.Previews
  alias IntellectualClub.Chat.Search
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationShare, LlmProvider}
  alias IntellectualClub.Sharing
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
    assert message_item_types(hd(messages)) == [:handoff_history, :handoff_message]

    handoff_text = message_text(hd(messages))
    assert String.starts_with?(handoff_text, "History")
    assert Regex.match?(~r/\*\*user\*\* \(\d{4}-\d{2}-\d{2} \d{2}:\d{2}Z\):/, handoff_text)
    refute Regex.match?(~r/\*\*user\*\* \(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/, handoff_text)
    assert String.contains?(handoff_text, "Current work")
    assert String.contains?(handoff_text, "Handoff message")
    assert String.contains?(handoff_text, "Continue from this summary.")

    stored_text = stored_message_text(hd(messages))
    refute String.contains?(stored_text, "Work continued")
    refute String.contains?(stored_text, "Conversation continued")
    refute String.contains?(stored_text, "<details>")
    refute String.contains?(stored_text, "<summary>")

    assert [%ChatMessageContent{} = history_content] =
             text_contents_for_item_type(hd(messages), :handoff_history)

    assert history_content.content_text == "Current work"
    assert history_content.content_json["entry_kind"] == "message"
    assert history_content.content_json["role"] == "user"
    assert is_binary(history_content.content_json["created_at"])
    assert Previews.message_preview(hd(messages), 100) == {"Current work", "user"}

    assert Enum.any?(
             Search.search_messages_in_chat(target.id, "Current work", actor).active,
             &(&1.id == summary_message.id)
           )

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

  test "manual handoff completion accepts a legacy answer item" do
    %{user: actor} = user_fixture()
    source = create_chat!(actor, "Source chat")

    {:ok, source_message} =
      Threads.add_message_to_end(source, :user, "Current work", actor: actor)

    {:ok, legacy_summary} =
      Threads.add_message(source, :assistant, "Legacy handoff summary",
        actor: actor,
        parent_id: source_message.id
      )

    assert message_item_types(
             Ash.load!(legacy_summary, [steps: [items: [:contents]]], actor: actor)
           ) == [:answer]

    assert {:ok, %{chat: target}} =
             Handoff.complete_manual_generation(legacy_summary.id, actor)

    assert [context_message] = messages_for_chat!(target.id, actor)
    assert message_item_types(context_message) == [:handoff_history, :handoff_message]
    assert String.contains?(message_text(context_message), "Legacy handoff summary")
  end

  test "POST /api/bff/chat-generation/:id/handoff persists summary as assistant message and creates child chat",
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

    {base_url, agent} = start_scripted_server!(scripts)
    configuration = create_llm_configuration!(actor, base_url)
    source = create_chat!(actor, "Manual source", llm_configuration_id: configuration.id)
    tool = create_tool_instance!(actor)
    create_chat_tool_binding!(actor, source, tool)

    {:ok, source_message} =
      Threads.add_message_to_end(source, :user, "Summarize me", actor: actor)

    conn = post(conn, ~p"/api/bff/chat-generation/#{source.id}/handoff", %{})
    payload = json_response(conn, 200)

    generation_message_id = payload["generation"]["message_id"]
    assert is_integer(generation_message_id)
    assert List.last(payload["branch"])["id"] == generation_message_id
    assert List.last(payload["branch"])["role"] == "assistant"
    assert Enum.at(payload["branch"], -2)["role"] == "user"

    assert [
             %{"item_type" => "handoff_request"}
           ] = Enum.at(payload["branch"], -2)["content"]["items"]

    generation_payload = wait_for_generation_to_finish(conn, generation_message_id)
    assert generation_payload["status"] == "done"

    assert Enum.any?(generation_payload["content"]["items"], fn item ->
             item["item_type"] == "handoff_summary"
           end)

    [original_message, handoff_prompt_message, summary_message] =
      messages_for_chat!(source.id, actor)

    assert original_message.id == source_message.id
    assert handoff_prompt_message.parent_id == source_message.id
    assert handoff_prompt_message.role == :user
    assert handoff_prompt_message.status == :done
    assert message_item_types(handoff_prompt_message) == [:handoff_request]

    assert String.contains?(
             message_text(handoff_prompt_message),
             "You are preparing a handoff summary"
           )

    assert summary_message.parent_id == handoff_prompt_message.id
    assert summary_message.role == :assistant
    assert summary_message.status == :done
    assert summary_message.generation_fence_token == nil
    assert summary_message.id == generation_message_id
    assert :handoff_summary in message_item_types(summary_message)
    refute :answer in message_item_types(summary_message)
    assert message_text(summary_message) == "Manual handoff summary."
    assert Previews.message_preview_text(summary_message) == "Manual handoff summary."

    search_hits = Search.search_messages_in_chat(source.id, "Manual handoff summary", actor)
    assert Enum.any?(search_hits.active, &(&1.id == summary_message.id))

    source_conn =
      get(
        build_conn() |> sign_in_conn(actor.username, password),
        ~p"/api/bff/chat-state/#{source.id}"
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
    assert message_item_types(hd(target_messages)) == [:handoff_history, :handoff_message]

    target_text = message_text(hd(target_messages))
    assert String.starts_with?(target_text, "History")
    assert String.contains?(target_text, "Summarize me")
    assert String.contains?(target_text, "Manual handoff summary.")
    refute String.contains?(target_text, "You are preparing a handoff summary")

    refute Enum.any?(target_messages, &(&1.status == :generating))

    target_payload =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chat-state/#{target_id}")
      |> json_response(200)

    [target_root] = target_payload["branch"]

    assert Enum.map(target_root["content"]["items"], & &1["item_type"]) == [
             "handoff_history",
             "handoff_message"
           ]

    history_parts =
      Enum.filter(target_root["content"]["parts"], &(&1["item_type"] == "handoff_history"))

    assert Enum.any?(history_parts, fn part ->
             part["text"] == "Summarize me" and
               part["handoff_entry"]["entry_kind"] == "message" and
               part["handoff_entry"]["role"] == "user" and
               is_binary(part["handoff_entry"]["created_at"]) and
               not Map.has_key?(part, "content_json")
           end)

    requests = Agent.get(agent, & &1.requests)
    [request] = Map.get(requests, "/chat/completions", [])
    assert "agent_management__handoff" in request_tool_names(request)
  end

  test "POST /api/bff/chat-generation/:id/handoff rejects non-owner", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: other, password: password} = user_fixture()
    conn = sign_in_conn(conn, other.username, password)

    source = create_chat!(owner, "Private source")

    conn = post(conn, ~p"/api/bff/chat-generation/#{source.id}/handoff", %{})
    assert response(conn, conn.status)
    assert conn.status in [403, 404]
  end

  test "manual handoff keeps tools and refuses their calls while preserving the prompt prefix",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    scripts = %{
      "/chat/completions" => [
        {200,
         sse_chunks([
           %{
             "id" => "chatcmpl-summary-tool-call",
             "object" => "chat.completion",
             "created" => 1,
             "model" => "test-chat-model",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => "",
                   "tool_calls" => [
                     %{
                       "id" => "call_manual_handoff_1",
                       "type" => "function",
                       "function" => %{
                         "name" => "agent_management__sleep",
                         "arguments" => Jason.encode!(%{"seconds" => 0})
                       }
                     }
                   ]
                 },
                 "finish_reason" => "tool_calls"
               }
             ]
           }
         ])},
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
    tool = create_tool_instance!(actor)
    create_chat_tool_binding!(actor, source, tool)

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

    refusal_text =
      "[tool error] Tool call refused while preparing a handoff summary. " <>
        "Create the handoff summary using the information already available."

    assert tool_result_texts(summary_message) == [refusal_text]

    requests = Agent.get(agent, & &1.requests)
    [first_request, second_request] = Map.get(requests, "/chat/completions", [])
    messages = first_request["messages"]

    assert [%{"role" => "system", "content" => system_content} | rest] = messages
    assert String.contains?(system_content, "Chat system prefix content.")
    refute String.contains?(system_content, "You are preparing a handoff summary")

    assert Enum.at(rest, -2) == %{"role" => "user", "content" => "Original user context"}

    assert %{"role" => "user", "content" => summary_request} = List.last(rest)
    assert String.contains?(summary_request, "You are preparing a handoff summary")
    assert String.contains?(summary_request, "Create the handoff summary now.")

    assert "agent_management__sleep" in request_tool_names(first_request)
    assert second_request["tools"] == first_request["tools"]
    assert second_request["tool_choice"] == first_request["tool_choice"]

    assert Enum.any?(second_request["messages"], fn message ->
             message["role"] == "tool" and
               message["tool_call_id"] == "call_manual_handoff_1" and
               message["content"] == refusal_text
           end)
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

  test "GET /api/bff/chat-state/:id includes parent and child handoff relations", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "State source")
    {:ok, source_message} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, %{chat: target}} =
      Handoff.create_handoff_chat(source, actor, "State summary",
        source_message_id: source_message.id
      )

    source_conn = get(conn, ~p"/api/bff/chat-state/#{source.id}")
    source_payload = json_response(source_conn, 200)

    children =
      source_payload["relations"]["children_by_message_id"][Integer.to_string(source_message.id)]

    assert [%{"chat_id" => child_id, "kind" => "handoff"}] = children
    assert child_id == target.id
    assert source_payload["relations"]["children_without_message"] == []

    target_conn =
      get(
        build_conn() |> sign_in_conn(actor.username, password),
        ~p"/api/bff/chat-state/#{target.id}"
      )

    target_payload = json_response(target_conn, 200)

    assert target_payload["relations"]["parent"]["chat_id"] == source.id
    assert target_payload["relations"]["parent"]["message_id"] == source_message.id
    assert target_payload["relations"]["parent"]["kind"] == "handoff"

    assert nav_labels(source_payload) == ["1", "2"]
    assert nav_chat_ids(source_payload) == [source.id, target.id]
    assert nav_labels(target_payload) == ["1", "2"]
    assert nav_chat_ids(target_payload) == [source.id, target.id]
  end

  test "GET /api/bff/chat-state/:id positions fork relations at their tool call item", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "Fork source")

    {:ok, assistant_message} =
      Threads.add_message_to_end(source, :assistant, "Before fork", actor: actor)

    step = first_step!(assistant_message.id, actor)

    tool_call_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 2, type: :tool_call},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    fork =
      Chat
      |> Ash.Changeset.for_create(
        :create_empty,
        %{
          note: "Investigate independently",
          parent_chat_id: source.id,
          parent_message_id: assistant_message.id,
          parent_tool_call_item_id: tool_call_item.id,
          parent_relation_kind: :fork,
          subagent: true
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, ancestor_message} =
      Threads.add_message_to_end(fork, :assistant, "Earlier copied fork", actor: actor)

    ancestor_step = first_step!(ancestor_message.id, actor)
    ancestor_call = create_tool_call_item!(ancestor_step.id, 2, actor)

    _ancestor_result =
      create_fork_instruction_result!(
        ancestor_step.id,
        ancestor_call.id,
        3,
        "Earlier task",
        actor
      )

    {:ok, copied_message} =
      Threads.add_message_to_end(fork, :assistant, "Before mirrored fork", actor: actor)

    copied_step = first_step!(copied_message.id, actor)
    copied_call = create_tool_call_item!(copied_step.id, 2, actor)

    _copied_result =
      create_fork_instruction_result!(
        copied_step.id,
        copied_call.id,
        3,
        "Investigate independently",
        actor
      )

    payload = conn |> get(~p"/api/bff/chat-state/#{source.id}") |> json_response(200)

    assert [relation] =
             payload["relations"]["children_by_message_id"][
               Integer.to_string(assistant_message.id)
             ]

    assert relation["chat_id"] == fork.id
    assert relation["kind"] == "fork"
    assert relation["parent_tool_call_item_id"] == tool_call_item.id
    assert relation["parent_step_id"] == step.id
    assert relation["parent_step_sequence"] == step.sequence
    assert relation["parent_item_sequence"] == tool_call_item.sequence
    assert relation["anchor_message_id"] == assistant_message.id
    assert relation["anchor_tool_call_item_id"] == tool_call_item.id
    assert relation["anchor_step_id"] == step.id
    assert relation["anchor_step_sequence"] == step.sequence
    assert relation["anchor_item_sequence"] == tool_call_item.sequence
    assert relation["background_task"] == false

    target_payload =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chat-state/#{fork.id}")
      |> json_response(200)

    parent_relation = target_payload["relations"]["parent"]

    assert parent_relation["chat_id"] == source.id
    assert parent_relation["message_id"] == assistant_message.id
    assert parent_relation["kind"] == "fork"
    assert parent_relation["parent_tool_call_item_id"] == tool_call_item.id
    assert parent_relation["parent_step_id"] == step.id
    assert parent_relation["parent_step_sequence"] == step.sequence
    assert parent_relation["parent_item_sequence"] == tool_call_item.sequence
    assert parent_relation["anchor_message_id"] == copied_message.id
    assert parent_relation["anchor_tool_call_item_id"] == copied_call.id
    assert parent_relation["anchor_step_id"] == copied_step.id
    assert parent_relation["anchor_step_sequence"] == copied_step.sequence
    assert parent_relation["anchor_item_sequence"] == copied_call.sequence
    refute parent_relation["anchor_tool_call_item_id"] == tool_call_item.id
    refute parent_relation["anchor_tool_call_item_id"] == ancestor_call.id
  end

  test "GET /api/bff/chat-state/:id keeps a fork parent relation without a local anchor", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "Fork source")

    {:ok, assistant_message} =
      Threads.add_message_to_end(source, :assistant, "Before fork", actor: actor)

    step = first_step!(assistant_message.id, actor)
    tool_call_item = create_tool_call_item!(step.id, 2, actor)

    fork =
      Chat
      |> Ash.Changeset.for_create(
        :create_empty,
        %{
          note: "Missing copied instruction",
          parent_chat_id: source.id,
          parent_message_id: assistant_message.id,
          parent_tool_call_item_id: tool_call_item.id,
          parent_relation_kind: :fork,
          subagent: true
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    payload = conn |> get(~p"/api/bff/chat-state/#{fork.id}") |> json_response(200)
    parent_relation = payload["relations"]["parent"]

    assert parent_relation["chat_id"] == source.id
    assert parent_relation["kind"] == "fork"
    assert parent_relation["parent_tool_call_item_id"] == tool_call_item.id
    assert parent_relation["anchor_message_id"] == nil
    assert parent_relation["anchor_tool_call_item_id"] == nil
    assert parent_relation["anchor_step_id"] == nil
    assert parent_relation["anchor_step_sequence"] == nil
    assert parent_relation["anchor_item_sequence"] == nil
  end

  test "GET /api/bff/chat-state/:id anchors spawn at the source tool call and not in the child",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "Spawn source")

    {:ok, assistant_message} =
      Threads.add_message_to_end(source, :assistant, "Before spawn", actor: actor)

    step = first_step!(assistant_message.id, actor)
    tool_call_item = create_tool_call_item!(step.id, 2, actor)

    spawn =
      Chat
      |> Ash.Changeset.for_create(
        :create_empty,
        %{
          note: "Investigate without copied history",
          parent_chat_id: source.id,
          parent_message_id: assistant_message.id,
          parent_tool_call_item_id: tool_call_item.id,
          parent_relation_kind: :spawn,
          subagent: true
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    source_payload = conn |> get(~p"/api/bff/chat-state/#{source.id}") |> json_response(200)

    assert [relation] =
             source_payload["relations"]["children_by_message_id"][
               Integer.to_string(assistant_message.id)
             ]

    assert relation["chat_id"] == spawn.id
    assert relation["kind"] == "spawn"
    assert relation["parent_tool_call_item_id"] == tool_call_item.id
    assert relation["parent_step_id"] == step.id
    assert relation["parent_step_sequence"] == step.sequence
    assert relation["parent_item_sequence"] == tool_call_item.sequence
    assert relation["anchor_message_id"] == assistant_message.id
    assert relation["anchor_tool_call_item_id"] == tool_call_item.id
    assert relation["anchor_step_id"] == step.id
    assert relation["anchor_step_sequence"] == step.sequence
    assert relation["anchor_item_sequence"] == tool_call_item.sequence

    child_payload =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chat-state/#{spawn.id}")
      |> json_response(200)

    parent_relation = child_payload["relations"]["parent"]

    assert parent_relation["chat_id"] == source.id
    assert parent_relation["message_id"] == assistant_message.id
    assert parent_relation["kind"] == "spawn"
    assert parent_relation["parent_tool_call_item_id"] == tool_call_item.id
    assert parent_relation["parent_step_id"] == step.id
    assert parent_relation["parent_step_sequence"] == step.sequence
    assert parent_relation["parent_item_sequence"] == tool_call_item.sequence
    assert parent_relation["anchor_message_id"] == nil
    assert parent_relation["anchor_tool_call_item_id"] == nil
    assert parent_relation["anchor_step_id"] == nil
    assert parent_relation["anchor_step_sequence"] == nil
    assert parent_relation["anchor_item_sequence"] == nil
    assert parent_relation["background_task"] == false
  end

  test "GET /api/bff/chat-state marks background subchat relations by target or source tool call",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "Background relation source")

    {:ok, assistant_message} =
      Threads.add_message_to_end(source, :assistant, "Create subchats", actor: actor)

    step = first_step!(assistant_message.id, actor)
    normal_tool_call = create_tool_call_item!(step.id, 2, actor)
    target_tool_call = create_tool_call_item!(step.id, 3, actor)
    fallback_tool_call = create_tool_call_item!(step.id, 4, actor)

    normal =
      create_relation_chat!(
        actor,
        source,
        assistant_message,
        normal_tool_call,
        :spawn,
        "Ordinary spawn"
      )

    target =
      create_relation_chat!(
        actor,
        source,
        assistant_message,
        target_tool_call,
        :spawn,
        "Canceled background spawn"
      )

    fallback =
      create_relation_chat!(
        actor,
        source,
        assistant_message,
        fallback_tool_call,
        :fork,
        "Completed background fork"
      )

    _target_task =
      create_subchat_background_task!(
        actor,
        source,
        assistant_message,
        step,
        target_tool_call,
        :spawn,
        :canceled,
        target.id
      )

    _fallback_task =
      create_subchat_background_task!(
        actor,
        source,
        assistant_message,
        step,
        fallback_tool_call,
        :fork,
        :completed,
        nil
      )

    payload = conn |> get(~p"/api/bff/chat-state/#{source.id}") |> json_response(200)

    relations =
      payload["relations"]["children_by_message_id"][
        Integer.to_string(assistant_message.id)
      ]
      |> Map.new(&{&1["chat_id"], &1})

    assert relations[normal.id]["background_task"] == false
    assert relations[target.id]["background_task"] == true
    assert relations[fallback.id]["background_task"] == true

    fallback_payload =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> get(~p"/api/bff/chat-state/#{fallback.id}")
      |> json_response(200)

    assert fallback_payload["relations"]["parent"]["background_task"] == true
  end

  test "GET /api/bff/chat-list includes relation hints for terminal continuations", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "List source", note: "List source")
    {:ok, source_message} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, %{chat: target}} =
      Handoff.create_handoff_chat(source, actor, "List summary",
        source_message_id: source_message.id
      )

    conn = get(conn, ~p"/api/bff/chat-list")
    payload = json_response(conn, 200)

    source_summary = Enum.find(payload["chats"], &(&1["id"] == source.id))
    target_summary = Enum.find(payload["chats"], &(&1["id"] == target.id))

    assert is_nil(source_summary)
    assert target_summary["parent_chat_id"] == source.id
    assert target_summary["parent_message_id"] == source_message.id
    assert target_summary["parent_relation_kind"] == "handoff"
    assert nav_labels(target_summary) == ["1", "2"]
    assert nav_chat_ids(target_summary) == [source.id, target.id]

    source_summary_payload =
      conn
      |> get(~p"/api/bff/chat-list/#{source.id}/summary")
      |> json_response(200)
      |> Map.fetch!("chat")

    assert nav_labels(source_summary_payload) == ["1", "2"]
    assert nav_chat_ids(source_summary_payload) == [source.id, target.id]

    summary_payload =
      conn
      |> get(~p"/api/bff/chat-list/#{target.id}/summary")
      |> json_response(200)
      |> Map.fetch!("chat")

    assert nav_labels(summary_payload) == ["1", "2"]
    assert nav_chat_ids(summary_payload) == [source.id, target.id]

    search_payload =
      conn
      |> get(~p"/api/bff/chat-list/search", %{"q" => "List summary"})
      |> json_response(200)

    search_target_summary = Enum.find(search_payload["chats"], &(&1["id"] == target.id))
    assert nav_labels(search_target_summary) == ["1", "2"]
    assert nav_chat_ids(search_target_summary) == [source.id, target.id]
  end

  test "continuation nav labels branched handoff families in preorder", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source = create_chat!(actor, "Branched family")
    {:ok, source_message} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, %{chat: child_a}} =
      Handoff.create_handoff_chat(source, actor, "Summary A",
        source_message_id: source_message.id
      )

    {:ok, %{chat: grandchild_a}} =
      Handoff.create_handoff_chat(child_a, actor, "Summary A child",
        source_message_id: child_a.last_message_id
      )

    {:ok, %{chat: child_b}} =
      Handoff.create_handoff_chat(source, actor, "Summary B",
        source_message_id: source_message.id
      )

    {:ok, %{chat: grandchild_b}} =
      Handoff.create_handoff_chat(child_b, actor, "Summary B child",
        source_message_id: child_b.last_message_id
      )

    payload =
      conn
      |> get(~p"/api/bff/chat-state/#{grandchild_b.id}")
      |> json_response(200)

    assert nav_labels(payload) == ["1", "2a", "3a", "2b", "3b"]

    assert nav_chat_ids(payload) == [
             source.id,
             child_a.id,
             grandchild_a.id,
             child_b.id,
             grandchild_b.id
           ]
  end

  test "continuation nav omits handoff chats inaccessible to actor", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: recipient, password: recipient_password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, "Shared nav bot", %{})
    configuration = create_llm_configuration!(owner, "http://127.0.0.1:9")
    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)

    source =
      create_chat!(owner, "Shared nav source",
        note: "Shared nav source",
        bot_id: bot.id,
        llm_configuration_id: configuration.id
      )

    {:ok, source_message} = Threads.add_message_to_end(source, :user, "Root", actor: owner)

    {:ok, %{chat: target}} =
      Handoff.create_handoff_chat(source, owner, "Private child",
        source_message_id: source_message.id
      )

    assert {:ok, _state} = Sharing.replace_chat_share_state(source.id, [group.id], owner)

    recipient_conn = sign_in_conn(conn, recipient.username, recipient_password)

    payload =
      recipient_conn
      |> get(~p"/api/bff/chat-state/#{source.id}")
      |> json_response(200)

    assert nav_labels(payload) == []

    recipient_conn
    |> get(~p"/api/bff/chat-state/#{target.id}")
    |> response(404)
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

  test "handoff re-expands a copied structured root with its original roles" do
    %{user: actor} = user_fixture()
    source = create_chat!(actor, "Copied structured source")

    {:ok, source_message} =
      Threads.add_message_with_items(
        source,
        :user,
        [
          %{
            type: :handoff_history,
            contents: [
              %{
                kind: :text,
                content_text: "Original request",
                content_json: %{
                  "entry_kind" => "message",
                  "role" => "user",
                  "created_at" => "2026-07-22T10:30:00Z"
                }
              },
              %{
                kind: :text,
                content_text: "Original answer",
                content_json: %{
                  "entry_kind" => "message",
                  "role" => "assistant",
                  "created_at" => "2026-07-22T10:31:00Z"
                }
              }
            ]
          },
          %{
            type: :handoff_message,
            contents: [%{kind: :text, content_text: "Copied transfer summary"}]
          }
        ],
        actor: actor,
        parent_id: nil,
        status: :done
      )

    assert {:ok, %{chat: target}} =
             Handoff.create_handoff_chat(source, actor, "Next transfer summary",
               source_message_id: source_message.id
             )

    [target_message] = messages_for_chat!(target.id, actor)
    history_contents = text_contents_for_item_type(target_message, :handoff_history)

    assert Enum.map(history_contents, & &1.content_text) == [
             "Original request",
             "Original answer",
             "Copied transfer summary"
           ]

    assert Enum.map(history_contents, & &1.content_json["role"]) == [
             "user",
             "assistant",
             "user"
           ]
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
    assert artifact_content.chat_message_item.type == :handoff_history
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
    create_steering_item!(step.id, 2, "Focus on the final result.", actor)
    long_final = String.duplicate("long-final-output ", 6_000)
    create_answer_item!(step.id, 3, long_final, actor)

    assert {:ok, %{chat: target}} =
             Handoff.create_handoff_chat(source, actor, "Continue after mixed assistant output.",
               source_message_id: assistant_message.id
             )

    [message] = messages_for_chat!(target.id, actor)
    text = message_text(message)

    assert Regex.scan(~r/\*\*assistant\*\* \(/, text) |> length() == 2
    assert Regex.scan(~r/\*\*user\*\* \(/, text) |> length() == 2
    assert String.contains?(text, "Short commentary.")
    assert String.contains?(text, "Focus on the final result.")
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

  defp create_relation_chat!(
         actor,
         source,
         parent_message,
         parent_tool_call_item,
         relation_kind,
         note
       ) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: note,
        parent_chat_id: source.id,
        parent_message_id: parent_message.id,
        parent_tool_call_item_id: parent_tool_call_item.id,
        parent_relation_kind: relation_kind,
        subagent: true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_subchat_background_task!(
         actor,
         source,
         source_message,
         source_step,
         source_tool_call_item,
         relation_kind,
         status,
         target_chat_id
       ) do
    BackgroundTask
    |> Ash.Changeset.for_create(
      :create,
      %{
        kind: Atom.to_string(relation_kind),
        adapter: Atom.to_string(relation_kind),
        status: status,
        function_name: Atom.to_string(relation_kind),
        arguments: %{},
        execution_context: %{"owner_id" => actor.id},
        runner_ref: %{},
        source_chat_id: source.id,
        source_message_id: source_message.id,
        source_step_id: source_step.id,
        source_tool_call_item_id: source_tool_call_item.id,
        target_chat_id: target_chat_id,
        finished_at: DateTime.utc_now()
      },
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

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(:create, %{bot_id: bot.id, user_group_id: group.id}, actor: actor)
    |> Ash.create!()
  end

  defp share_configuration!(actor, configuration, group) do
    LlmConfigurationShare
    |> Ash.Changeset.for_create(
      :create,
      %{llm_configuration_id: configuration.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!()
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
    |> Ash.Query.load([:file, :chat_message_item])
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
    create_text_item!(step_id, sequence, :answer, text, actor)
  end

  defp create_steering_item!(step_id, sequence, text, actor) do
    create_text_item!(step_id, sequence, :steering, text, actor)
  end

  defp create_tool_call_item!(step_id, sequence, actor) do
    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_step_id: step_id, sequence: sequence, type: :tool_call},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_fork_instruction_result!(step_id, tool_call_item_id, sequence, task, actor) do
    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: step_id,
          sequence: sequence,
          type: :tool_result,
          tool_call_item_id: tool_call_item_id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :opaque,
        content_json: %{
          "raw" => %{
            "fork_instruction" => %{
              "subagent" => true,
              "task" => task
            }
          }
        }
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    item
  end

  defp create_text_item!(step_id, sequence, type, text, actor) do
    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step_id, sequence: sequence, type: type},
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
    if Enum.any?(message_item_types(message), &(&1 in [:handoff_history, :handoff_message])) do
      History.project_user_input_text(message)
    else
      Previews.message_preview_text(message)
    end
  end

  defp stored_message_text(%ChatMessage{} = message) do
    message.steps
    |> List.wrap()
    |> Enum.sort_by(&(&1.sequence || 0))
    |> Enum.flat_map(&List.wrap(&1.items))
    |> Enum.sort_by(&(&1.sequence || 0))
    |> Enum.flat_map(&List.wrap(&1.contents))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(&(&1.sequence || 0))
    |> Enum.map_join("\n", &(&1.content_text || ""))
  end

  defp text_contents_for_item_type(%ChatMessage{} = message, item_type) do
    message.steps
    |> List.wrap()
    |> Enum.sort_by(&(&1.sequence || 0))
    |> Enum.flat_map(&List.wrap(&1.items))
    |> Enum.filter(&(&1.type == item_type))
    |> Enum.flat_map(&List.wrap(&1.contents))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(&(&1.sequence || 0))
  end

  defp message_item_types(%ChatMessage{} = message) do
    message.steps
    |> List.wrap()
    |> Enum.sort_by(&(&1.sequence || 0))
    |> Enum.flat_map(&List.wrap(&1.items))
    |> Enum.sort_by(&(&1.sequence || 0))
    |> Enum.map(& &1.type)
  end

  defp tool_result_texts(%ChatMessage{} = message) do
    message.steps
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(&1.items))
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&List.wrap(&1.contents))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map(&(&1.content_text || ""))
  end

  defp request_tool_names(request) when is_map(request) do
    request
    |> Map.get("tools", [])
    |> List.wrap()
    |> Enum.map(fn tool -> get_in(tool, ["function", "name"]) end)
    |> Enum.filter(&is_binary/1)
  end

  defp nav_labels(%{"continuation_nav" => nav}) when is_list(nav) do
    Enum.map(nav, & &1["label"])
  end

  defp nav_labels(_payload), do: []

  defp nav_chat_ids(%{"continuation_nav" => nav}) when is_list(nav) do
    Enum.map(nav, & &1["chat_id"])
  end

  defp nav_chat_ids(_payload), do: []

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
