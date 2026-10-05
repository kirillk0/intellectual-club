defmodule IntellectualClub.Chat.HandoffTest do
  @moduledoc """
  Handoff service (`IntellectualClub.Chat.Handoff`): creating the continuation
  chat, the manual summary generation and the rendered history of the
  continuation's first message, including truncation under the token budget.

  The BFF contract (endpoint, relations, continuation navigation) is covered by
  `IntellectualClubWeb.Bff.ChatHandoffTest`.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.HandoffTestHelpers

  require Ash.Query

  alias IntellectualClub.Chat.{ChatMessageContent, Handoff, Previews}
  alias IntellectualClub.Chat.{Search, Threads}
  alias IntellectualClub.Files
  alias IntellectualClub.TokenCounter

  describe "create_handoff_chat/4 and manual completion" do
    setup do
      put_app_env(:missed_notifications, :raise, :ash)
      :ok
    end

    test "creates the linked continuation chat with the rendered history and the source chat settings" do
      %{user: actor} = user_fixture()

      source = create_empty_chat!(actor)

      {:ok, source_message} =
        Threads.add_message_to_end(source, :user, "Current work", actor: actor)

      block = create_knowledge_block!(actor, name: "Block", content: "Knowledge")
      tool = create_tool_instance!(actor, type: "native-agent-management")

      _block_binding =
        create_chat_block_binding!(actor, source, block, enabled: false, sequence: 7)

      _tool_binding = create_chat_tool_binding!(actor, source, tool, sequence: 3)

      assert {:ok, %{chat: target, message: summary_message, generation: nil}} =
               Handoff.create_handoff_chat(source, actor, "Continue from this summary.",
                 source_message_id: source_message.id
               )

      assert target.parent_chat_id == source.id
      assert target.parent_message_id == source_message.id
      assert target.parent_relation_kind == :handoff
      assert target.last_message_id == summary_message.id

      messages = messages_for_chat!(actor, target.id)
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

      # The binding copy contract (order, flags, several bindings) is owned by
      # `POST /api/ash/chats/:id/copy`; a handoff only has to carry it over.
      assert %{blocks: [{block_id, false, 7}], tools: [{tool_id, true, 3}]} =
               settings = chat_binding_settings!(actor, source)

      assert {block_id, tool_id} == {block.id, tool.id}
      assert chat_binding_settings!(actor, target) == settings
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

      assert [context_message] = messages_for_chat!(actor, target.id)
      assert message_item_types(context_message) == [:handoff_history, :handoff_message]
      assert String.contains?(message_text(context_message), "Legacy handoff summary")
    end
  end

  describe "continuation history" do
    test "nested handoff expands parent history and skips child summary root" do
      %{user: actor} = user_fixture()

      source = create_empty_chat!(actor)
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

      [message] = messages_for_chat!(actor, second_child.id)
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

      assert {:ok, %{chat: target}} =
               Handoff.create_handoff_chat(source, actor, "Next transfer summary",
                 source_message_id: source_message.id
               )

      [target_message] = messages_for_chat!(actor, target.id)
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

      assert {:ok, %{chat: target}} =
               Handoff.create_handoff_chat(source, actor, "Continue with the report.",
                 source_message_id: source_message.id
               )

      [message] = messages_for_chat!(actor, target.id)
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

      assert {:ok, %{chat: target}} =
               Handoff.create_handoff_chat(source, actor, "Continue after long answer.",
                 source_message_id: assistant_message.id
               )

      [message] = messages_for_chat!(actor, target.id)
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
      create_steering_item!(step.id, 2, "Focus on the final result.", actor)
      long_final = String.duplicate("long-final-output ", 6_000)
      create_answer_item!(step.id, 3, long_final, actor)

      assert {:ok, %{chat: target}} =
               Handoff.create_handoff_chat(
                 source,
                 actor,
                 "Continue after mixed assistant output.",
                 source_message_id: assistant_message.id
               )

      [message] = messages_for_chat!(actor, target.id)
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

      assert {:ok, %{chat: target, message: target_message}} =
               Handoff.create_handoff_chat(source, actor, "Continue massive work.",
                 source_message_id: last_message.id
               )

      [loaded_target_message] = messages_for_chat!(actor, target.id)
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

  defp create_answer_item!(step_id, sequence, text, actor) do
    create_text_item!(actor, step_id, text, sequence: sequence, type: :answer)
  end

  defp create_steering_item!(step_id, sequence, text, actor) do
    create_text_item!(actor, step_id, text, sequence: sequence, type: :steering)
  end

  defp timestamp_minute_text(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%MZ")
  end
end
