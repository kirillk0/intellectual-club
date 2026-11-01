defmodule IntellectualClub.Chat.HandoffTest do
  @moduledoc """
  Same-chat compaction service (`IntellectualClub.Chat.Handoff`): manual
  completion, checkpoint publication and rendered history under the token budget.

  The BFF contract (endpoint and fork/spawn relations) is covered by
  `IntellectualClubWeb.Bff.ChatHandoffTest`.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.HandoffTestHelpers

  require Ash.Query

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageContent, Handoff, Previews}
  alias IntellectualClub.Chat.{Search, Threads}
  alias IntellectualClub.Files
  alias IntellectualClub.TokenCounter
  alias IntellectualClub.SqlCapture

  describe "manual completion" do
    setup do
      put_app_env(:missed_notifications, :raise, :ash)
      :ok
    end

    test "compaction keeps subagent lineage and root chats unchanged" do
      %{user: actor} = user_fixture()
      root = create_empty_chat!(actor)
      creator = create_tool_instance!(actor, type: "native-agent-management")
      source = create_subchat!(actor, root, :spawn, parent_tool_instance_id: creator.id)

      for chat <- [root, source] do
        {:ok, _input} = Threads.add_message_to_end(chat, :user, "Current work", actor: actor)
        {:ok, prompt} = Handoff.prepare_manual_handoff_message(chat.id, actor)

        {:ok, summary} =
          Threads.add_message(chat, :assistant, "Continue the work.",
            actor: actor,
            parent_id: prompt.id,
            item_type: :handoff_summary
          )

        assert {:ok, %{chat: target, message: checkpoint, generation: nil}} =
                 Handoff.complete_manual_generation(summary.id, actor)

        assert target.id == chat.id
        assert checkpoint.chat_id == chat.id
        assert target.subagent == chat.subagent
        assert target.parent_chat_id == chat.parent_chat_id
        assert target.parent_relation_kind == chat.parent_relation_kind
        assert target.parent_tool_instance_id == chat.parent_tool_instance_id
      end
    end

    test "appends a structured checkpoint with searchable history without copying settings" do
      %{user: actor} = user_fixture()

      source = create_empty_chat!(actor)

      {:ok, source_message} =
        Threads.add_message_to_end(source, :user, "Current work", actor: actor)

      block = create_knowledge_block!(actor, name: "Block", content: "Knowledge")
      tool = create_tool_instance!(actor, type: "native-agent-management")

      _block_binding =
        create_chat_block_binding!(actor, source, block, enabled: false, sequence: 7)

      _tool_binding = create_chat_tool_binding!(actor, source, tool, sequence: 3)

      {:ok, prompt} = Handoff.prepare_manual_handoff_message(source.id, actor)

      {:ok, summary} =
        Threads.add_message(source, :assistant, "Continue from this summary.",
          actor: actor,
          parent_id: prompt.id,
          item_type: :handoff_summary
        )

      assert {:ok, %{chat: target, message: summary_message, generation: nil}} =
               Handoff.complete_manual_generation(summary.id, actor)

      assert target.id == source.id
      assert target.parent_chat_id == nil
      assert target.last_message_id == summary_message.id
      assert summary_message.parent_id == summary.id

      assert [original, request, answer, checkpoint] = messages_for_chat!(actor, target.id)
      assert [original.id, request.id, answer.id] == [source_message.id, prompt.id, summary.id]
      assert checkpoint.id == summary_message.id
      messages = [checkpoint]
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

      assert child_ids == []

      # Same-chat compaction leaves binding identities and settings untouched.
      assert %{blocks: [{block_id, false, 7}], tools: [{tool_id, true, 3}]} =
               settings = chat_binding_settings!(actor, source)

      assert {block_id, tool_id} == {block.id, tool.id}
      assert chat_binding_settings!(actor, target) == settings
    end

    test "manual completion keeps the chat selector rather than the summary configuration" do
      %{user: actor} = user_fixture()
      summarizing = create_configuration!(actor)
      selected = create_configuration!(actor)
      source = create_empty_chat!(actor, llm_configuration_id: summarizing.id)

      {:ok, source_message} =
        Threads.add_message_to_end(source, :user, "Current work", actor: actor)

      {:ok, summary} =
        Threads.add_message(source, :assistant, "Handoff summary",
          actor: actor,
          parent_id: source_message.id,
          llm_configuration_id: summarizing.id
        )

      # The next user message follows the current chat selector.
      source
      |> Ash.Changeset.for_update(:update, %{llm_configuration_id: selected.id}, actor: actor)
      |> Ash.update!(actor: actor)

      assert {:ok, %{chat: target, generation: nil}} =
               Handoff.complete_manual_generation(summary.id, actor)

      assert target.id == source.id
      assert target.llm_configuration_id == selected.id
    end

    test "manual handoff completion accepts a legacy answer item" do
      %{user: actor} = user_fixture()
      source = create_empty_chat!(actor)

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

      assert target.id == source.id
      assert [_source, _summary, context_message] = messages_for_chat!(actor, target.id)
      assert context_message.parent_id == legacy_summary.id
      assert message_item_types(context_message) == [:handoff_history, :handoff_message]
      assert String.contains?(message_text(context_message), "Legacy handoff summary")
    end
  end

  describe "manual checkpoints" do
    test "completion is idempotent and does not change a different selected branch" do
      %{user: actor} = user_fixture()
      source = create_empty_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(source, :user, "Original task", actor: actor)

      {:ok, summary} =
        Threads.add_message(source, :assistant, "Compacted summary",
          actor: actor,
          parent_id: root.id,
          item_type: :handoff_summary
        )

      {:ok, sibling} =
        Threads.add_message(source, :assistant, "Selected sibling",
          actor: actor,
          parent_id: root.id
        )

      assert {:ok, first} = Handoff.complete_manual_generation(summary.id, actor)
      assert {:ok, second} = Handoff.complete_manual_generation(summary.id, actor)
      assert first.chat.id == source.id
      assert first.message.id == second.message.id
      assert first.message.parent_id == summary.id
      assert second.chat.last_message_id == sibling.id

      checkpoints =
        messages_for_chat!(actor, source.id)
        |> Enum.filter(&(:handoff_message in message_item_types(&1)))

      assert Enum.map(checkpoints, & &1.id) == [first.message.id]
    end
  end

  describe "prepare_compaction/3" do
    test "reads the owned generating message branch without publishing a checkpoint" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Original task", actor: actor)
      message = create_message!(actor, chat, parent_id: root.id, status: :generating)
      step = create_step!(actor, message, status: :waiting_tools)
      create_text_item!(actor, step, "Persisted answer")

      {:ok, sibling} =
        Threads.add_message(chat, :assistant, "OTHER BRANCH", actor: actor, parent_id: root.id)

      before = messages_for_chat!(actor, chat.id)

      assert {:ok, rolloff} = Handoff.prepare_compaction(message.id, actor, "  Full summary  ")
      assert rolloff.handoff_message == "Full summary"
      assert Enum.map(rolloff.history, & &1.text) == ["Original task", "Persisted answer"]
      refute rolloff.artifact.payload =~ "OTHER BRANCH"
      assert messages_for_chat!(actor, chat.id) == before
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == sibling.id
    end

    test "requires an owned assistant message and a nonempty string summary" do
      %{user: actor} = user_fixture()
      %{user: other} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [actor, other]})

      chat =
        create_empty_chat!(actor,
          bot_id: create_bot!(actor).id,
          llm_configuration_id: create_configuration!(actor).id
        )

      {:ok, root} = Threads.add_message_to_end(chat, :user, "Original task", actor: actor)
      message = create_message!(actor, chat, parent_id: root.id)
      share_chat!(actor, chat, group)
      assert Ash.get!(ChatMessage, message.id, actor: other).id == message.id

      assert {:error, :not_found} = Handoff.prepare_compaction(message.id, other, "Summary")
      assert {:error, :forbidden} = Handoff.prepare_compaction(message.id, nil, "Summary")
      assert {:error, :not_found} = Handoff.prepare_compaction(root.id, actor, "Summary")
      assert {:error, :not_found} = Handoff.prepare_compaction(-1, actor, "Summary")
      assert {:error, :invalid_message_id} = Handoff.prepare_compaction(nil, actor, "Summary")
      assert {:error, :empty_summary} = Handoff.prepare_compaction(message.id, actor, " ")
      assert {:error, :invalid_summary} = Handoff.prepare_compaction(message.id, actor, nil)
    end

    @tag :whitebox
    test "resolves the source chat from message ids before reading the branch trace" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      message = create_message!(actor, chat)
      step = create_step!(actor, message)
      create_text_item!(actor, step, "Original answer")

      assert {{:ok, _rolloff}, capture} =
               SqlCapture.measure(fn ->
                 Handoff.prepare_compaction(message.id, actor, "Summary")
               end)

      [source_lookup | _] = SqlCapture.selects_from(capture.queries, "chat_messages")
      assert Enum.sort(source_lookup.columns) == ["chat_id", "id"]

      before_chat = Enum.take_while(capture.queries, &(&1.source != "chats"))

      for table <- ["chat_message_steps", "chat_message_items", "chat_message_contents"] do
        assert SqlCapture.selects_from(before_chat, table) == []
      end
    end
  end

  describe "checkpoint history" do
    test "successive checkpoints archive originals rather than checkpoint copies" do
      %{user: actor} = user_fixture()
      source = create_empty_chat!(actor)
      {:ok, _root} = Threads.add_message_to_end(source, :user, "Root task", actor: actor)

      {:ok, answer} =
        Threads.add_message_to_end(source, :assistant, "Original answer", actor: actor)

      %{message: first} = append_checkpoint!(actor, source, answer, "First summary")
      {:ok, followup} = Threads.add_message_to_end(source, :user, "Follow-up", actor: actor)
      assert followup.parent_id == first.id

      {:ok, next_answer} =
        Threads.add_message_to_end(source, :assistant, "Next answer", actor: actor)

      %{message: second} = append_checkpoint!(actor, source, next_answer, "Second summary")
      message = List.last(messages_for_chat!(actor, source.id))
      assert message.id == second.id
      text = message_text(message)

      for original <- ["Root task", "Original answer", "Follow-up", "Next answer"] do
        assert length(String.split(text, original)) == 2
      end

      assert text =~ "Second summary"
      refute text =~ "First summary"
      [artifact] = media_contents_for_message!(message.id, actor)
      assert {:ok, {_file, archive}} = Files.load_payload(artifact.file_id)
      refute archive =~ "summary"
      refute archive =~ "full_conversation.md"
    end

    test "a standalone checkpoint seed retains its original roles" do
      %{user: actor} = user_fixture()
      source = create_empty_chat!(actor)

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

      %{message: checkpoint} =
        append_checkpoint!(actor, source, source_message, "Next transfer summary")

      target_message = List.last(messages_for_chat!(actor, source.id))
      assert target_message.id == checkpoint.id
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

      source = create_empty_chat!(actor)
      {:ok, file} = Files.create_from_binary("report.md", "text/markdown", "# Report")

      {:ok, source_message} =
        Threads.add_message_to_end(source, :user, "",
          actor: actor,
          contents: [
            %{kind: :text, content_text: "See attached report."},
            %{kind: :media, file_id: file.id}
          ]
        )

      append_checkpoint!(actor, source, source_message, "Continue with the report.")
      message = List.last(messages_for_chat!(actor, source.id))
      text = message_text(message)

      assert String.contains?(text, "See attached report.")
      assert String.contains?(text, "file_id=#{file.external_id}")
      assert String.contains?(text, "filename=\"report.md\"")
      assert String.contains?(text, "/api/bff/chat-messages/#{source_message.id}/contents/")
    end

    test "handoff truncates assistant history and attaches full conversation" do
      %{user: actor} = user_fixture()

      source = create_empty_chat!(actor)

      {:ok, _user_message} =
        Threads.add_message_to_end(source, :user, "Short prompt", actor: actor)

      long_answer = String.duplicate("assistant-long-output ", 6_000)

      {:ok, assistant_message} =
        Threads.add_message_to_end(source, :assistant, long_answer, actor: actor)

      append_checkpoint!(actor, source, assistant_message, "Continue after long answer.")
      message = List.last(messages_for_chat!(actor, source.id))
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

      source = create_empty_chat!(actor)
      {:ok, user_message} = Threads.add_message_to_end(source, :user, "Question", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message_to_end(source, :assistant, "Short commentary.",
          actor: actor,
          parent_id: user_message.id
        )

      step = first_step!(actor, assistant_message.id)
      create_text_item!(actor, step, "Focus on the final result.", type: :steering, sequence: 2)
      long_final = String.duplicate("long-final-output ", 6_000)
      create_text_item!(actor, step, long_final, type: :answer, sequence: 3)

      append_checkpoint!(
        actor,
        source,
        assistant_message,
        "Continue after mixed assistant output."
      )

      message = List.last(messages_for_chat!(actor, source.id))
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

    test "hard middle-out keeps the first and latest entries and attaches the full conversation" do
      %{user: actor} = user_fixture()
      source = create_empty_chat!(actor)
      wide_text = fn index -> "message-#{index} " <> String.duplicate("wide-context ", 90) end

      # A copied handoff history re-expands into one entry per content, so 129
      # entries plus one regular message exceed the budget even when every user
      # entry is cut to the massive-history limit.
      history =
        for index <- 1..129 do
          %{
            kind: :text,
            content_text: wide_text.(index |> Integer.to_string() |> String.pad_leading(3, "0")),
            content_json: %{
              "entry_kind" => "message",
              "role" => "user",
              "created_at" => "2026-07-22T10:30:00Z"
            }
          }
        end

      {:ok, _copied_root} =
        Threads.add_message_with_items(
          source,
          :user,
          [%{type: :handoff_history, contents: history}],
          actor: actor,
          parent_id: nil,
          status: :done
        )

      {:ok, last_message} =
        Threads.add_message_to_end(source, :user, wide_text.("130"), actor: actor)

      %{chat: target, message: target_message} =
        append_checkpoint!(actor, source, last_message, "Continue massive work.")

      loaded_target_message = List.last(messages_for_chat!(actor, source.id))
      text = message_text(loaded_target_message)

      assert TokenCounter.estimate(text) <= 20_000
      assert String.contains?(text, "message-001")
      assert String.contains?(text, "message-130")
      assert text =~ ~r/omitted \d+ middle messages/
      refute String.contains?(text, "message-002 ")
      assert String.contains?(text, "full_conversation.md")

      [artifact_content] = media_contents_for_message!(target_message.id, actor)
      assert artifact_content.file.filename == "full_conversation.md"
      assert artifact_content.file.mime_type == "text/markdown"
      assert {:ok, {_file, payload}} = Files.load_payload(artifact_content.file_id)
      assert String.contains?(payload, "message-002 ")

      assert target.last_message_id == target_message.id
    end
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

  defp timestamp_minute_text(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%MZ")
  end
end
