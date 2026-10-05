defmodule IntellectualClubWeb.Bff.ChatHandoffTest do
  @moduledoc """
  BFF contract of chat continuations: the manual handoff endpoint, subchat
  relations in chat state (handoff, fork, spawn, background tasks) and the
  continuation navigation in chat state (chat lists: `IntellectualClubWeb.Bff.ChatListTest`).

  The handoff service and the rendered history live in
  `IntellectualClub.Chat.HandoffTest`.
  """

  use IntellectualClubWeb.ConnCase, async: false

  import IntellectualClub.HandoffTestHelpers

  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.{Chat, ChatMessageContent, ChatMessageItem, Handoff, Previews}
  alias IntellectualClub.Chat.{Search, Threads}
  alias IntellectualClub.Sharing

  describe "manual handoff" do
    test "POST /api/bff/chat-generation/:id/handoff persists the summary and creates the child chat",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      scripts = %{
        "/chat/completions" => [
          chat_completion_response("Manual handoff summary.")
        ]
      }

      {base_url, agent} = start_scripted_server!(scripts)

      configuration =
        create_summary_configuration!(actor, base_url)

      source = create_empty_chat!(actor, llm_configuration_id: configuration.id)
      tool = create_tool_instance!(actor, type: "native-agent-management")
      create_chat_tool_binding!(actor, source, tool, sequence: 3)

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
        messages_for_chat!(actor, source.id)

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

      target_messages = messages_for_chat!(actor, target_id)
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

    test "POST /api/bff/chat-generation/:id/handoff rejects a non-owner", %{conn: conn} do
      %{user: owner} = user_fixture()
      %{user: other, password: password} = user_fixture()
      conn = sign_in_conn(conn, other.username, password)

      source = create_empty_chat!(owner)

      conn = post(conn, ~p"/api/bff/chat-generation/#{source.id}/handoff", %{})
      assert response(conn, conn.status)
      assert conn.status in [403, 404]
    end

    test "keeps tools and refuses their calls while preserving the prompt prefix",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      scripts = %{
        "/chat/completions" => [
          chat_completion_response(
            %{
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
            "tool_calls"
          ),
          chat_completion_response("Summary from same prompt prefix.")
        ]
      }

      {base_url, agent} = start_scripted_server!(scripts)

      configuration =
        create_summary_configuration!(actor, base_url)

      source = create_empty_chat!(actor, llm_configuration_id: configuration.id)

      block =
        create_knowledge_block!(actor,
          name: "Chat prefix",
          content: "Chat system prefix content."
        )

      create_chat_block_binding!(actor, source, block, sequence: 7, enabled: true)
      tool = create_tool_instance!(actor, type: "native-agent-management")
      create_chat_tool_binding!(actor, source, tool, sequence: 3)

      {:ok, _source_message} =
        Threads.add_message_to_end(source, :user, "Original user context", actor: actor)

      assert {:ok, context} = Handoff.manual_handoff(source.id, actor)
      generation_payload = wait_for_generation_to_finish(conn, context.message_id)
      assert generation_payload["status"] == "done"

      [_original_message, handoff_prompt_message, summary_message] =
        messages_for_chat!(actor, source.id)

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

    test "uses the bot handoff message block content as summary prompt", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      scripts = %{
        "/chat/completions" => [
          chat_completion_response("Summary from custom handoff prompt.")
        ]
      }

      {base_url, agent} = start_scripted_server!(scripts)

      configuration =
        create_summary_configuration!(actor, base_url)

      handoff_block =
        create_knowledge_block!(actor,
          name: "Handoff block title",
          content: "Custom handoff prompt body.\nUse only the useful continuation state."
        )

      bot =
        create_bot!(actor, name: "Custom handoff bot", handoff_message_block_id: handoff_block.id)

      source =
        create_empty_chat!(actor, bot_id: bot.id, llm_configuration_id: configuration.id)

      {:ok, _source_message} =
        Threads.add_message_to_end(source, :user, "Original user context", actor: actor)

      assert {:ok, context} = Handoff.manual_handoff(source.id, actor)
      generation_payload = wait_for_generation_to_finish(conn, context.message_id)
      assert generation_payload["status"] == "done"

      [_original_message, handoff_prompt_message, summary_message] =
        messages_for_chat!(actor, source.id)

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
  end

  describe "GET /api/bff/chat-state relations" do
    test "include parent and child handoff relations", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      source = create_empty_chat!(actor)
      {:ok, source_message} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

      {:ok, %{chat: target}} =
        Handoff.create_handoff_chat(source, actor, "State summary",
          source_message_id: source_message.id
        )

      source_conn = get(conn, ~p"/api/bff/chat-state/#{source.id}")
      source_payload = json_response(source_conn, 200)

      children =
        source_payload["relations"]["children_by_message_id"][
          Integer.to_string(source_message.id)
        ]

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

    test "position fork relations at their tool call item", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      source = create_empty_chat!(actor)

      {:ok, assistant_message} =
        Threads.add_message_to_end(source, :assistant, "Before fork", actor: actor)

      step = first_step!(actor, assistant_message.id)

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

      ancestor_step = first_step!(actor, ancestor_message.id)
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

      copied_step = first_step!(actor, copied_message.id)
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

    test "keep a fork parent relation without a local anchor", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      source = create_empty_chat!(actor)

      {:ok, assistant_message} =
        Threads.add_message_to_end(source, :assistant, "Before fork", actor: actor)

      step = first_step!(actor, assistant_message.id)
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

    test "anchor spawn at the source tool call and not in the child",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      source = create_empty_chat!(actor)

      {:ok, assistant_message} =
        Threads.add_message_to_end(source, :assistant, "Before spawn", actor: actor)

      step = first_step!(actor, assistant_message.id)
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

    test "mark background subchat relations by target or source tool call",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      source = create_empty_chat!(actor)

      {:ok, assistant_message} =
        Threads.add_message_to_end(source, :assistant, "Create subchats", actor: actor)

      step = first_step!(actor, assistant_message.id)
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
  end

  describe "continuation navigation" do
    test "labels branched handoff families in preorder", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      source = create_empty_chat!(actor)
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

    test "omits handoff chats inaccessible to the actor", %{conn: conn} do
      %{user: owner} = user_fixture()
      %{user: recipient, password: recipient_password} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})

      bot = create_bot!(owner, name: "Shared nav bot")

      configuration =
        create_summary_configuration!(owner, "http://127.0.0.1:9")

      share_bot!(owner, bot, group)
      share_configuration!(owner, configuration, group)

      source =
        create_empty_chat!(owner,
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
end
