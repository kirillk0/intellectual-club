defmodule IntellectualClub.Chat.QueuedMessagesTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.QueuedMessage
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files

  test "follow-ups are listed FIFO and can be edited" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    {:ok, anchor} = Threads.add_message_to_end(chat, :assistant, "Answer", actor: actor)

    assert {:ok, first} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "First"}, actor)

    assert {:ok, second} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "Second"}, actor)

    assert first.anchor_message_id == anchor.id
    assert second.anchor_message_id == anchor.id

    assert {:ok, [listed_first, listed_second]} = QueuedMessages.list_for_chat(chat.id, actor)
    assert [listed_first.id, listed_second.id] == [first.id, second.id]

    assert {:ok, edited} =
             QueuedMessages.update(first.id, %{content: "Edited", remove_content_ids: []}, actor)

    assert [%{kind: :text, content_text: "Edited", sequence: 1}] = edited.contents
  end

  test "editing and canceling release files that remain owned by the queue" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    {:ok, _anchor} = Threads.add_message_to_end(chat, :assistant, "Answer", actor: actor)
    {:ok, first_file} = Files.create_from_binary("first.txt", "text/plain", "first")
    {:ok, second_file} = Files.create_from_binary("second.txt", "text/plain", "second")

    assert {:ok, queued_message} =
             QueuedMessages.enqueue_follow_up(
               chat.id,
               %{content: "With file", file_ids: [first_file.id]},
               actor
             )

    media = Enum.find(queued_message.contents, &(&1.kind == :media))

    assert {:ok, edited} =
             QueuedMessages.update(
               queued_message.id,
               %{
                 content: "Replacement",
                 remove_content_ids: [media.id],
                 file_ids: [second_file.id]
               },
               actor
             )

    assert {:error, _error} = Files.load_payload(first_file.id)
    assert Enum.map(edited.contents, & &1.kind) == [:text, :media]
    assert Enum.find(edited.contents, &(&1.kind == :media)).file_id == second_file.id

    assert {:ok, canceled} = QueuedMessages.cancel(edited.id, actor)
    assert canceled.status == :canceled
    assert canceled.contents == []
    assert {:error, _error} = Files.load_payload(second_file.id)
    assert {:ok, []} = QueuedMessages.list_for_chat(chat.id, actor)
  end

  test "send-next only retries the idle FIFO head and reanchors the backlog" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    {:ok, anchor} = Threads.add_message_to_end(chat, :assistant, "Old answer", actor: actor)

    assert {:ok, first} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "First"}, actor)

    assert {:ok, second} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "Second"}, actor)

    assert first.anchor_message_id == anchor.id
    assert {:ok, _blocked} = QueuedMessages.mark_blocked(first, :generation_error, actor)

    {:ok, new_anchor} =
      Threads.add_message_to_end(chat, :assistant, "Recovered answer", actor: actor)

    assert {:error, :not_queue_head} = QueuedMessages.send_next(second.id, actor)
    assert {:ok, retried} = QueuedMessages.send_next(first.id, actor)
    assert retried.status == :pending
    assert retried.blocked_reason == nil
    assert retried.anchor_message_id == new_anchor.id

    assert {:ok, [_first, reanchored_second]} = QueuedMessages.list_for_chat(chat.id, actor)
    assert reanchored_second.anchor_message_id == new_anchor.id
    assert reanchored_second.status == :pending
    assert reanchored_second.blocked_reason == nil
  end

  test "canceling the FIFO head pauses the remaining backlog" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    {:ok, _anchor} = Threads.add_message_to_end(chat, :assistant, "Answer", actor: actor)

    assert {:ok, first} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "First"}, actor)

    assert {:ok, second} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "Second"}, actor)

    assert {:ok, canceled} = QueuedMessages.cancel(first.id, actor)
    assert canceled.status == :canceled

    assert {:ok, [paused]} = QueuedMessages.list_for_chat(chat.id, actor)
    assert paused.id == second.id
    assert paused.status == :blocked
    assert paused.blocked_reason == "head_removed"
  end

  test "send-next rejects a chat with an active generation" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    {:ok, anchor} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

    generating =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: anchor.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:ok, queued_message} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "Later"}, actor)

    assert queued_message.anchor_message_id == generating.id
    assert {:error, :generation_active} = QueuedMessages.send_next(queued_message.id, actor)
  end

  test "deleting a steering target cascades pending and delivered queue records" do
    %{user: actor} = user_fixture()

    for status <- [:pending, :delivered] do
      chat = create_chat!(actor)
      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      generation =
        ChatMessage
        |> Ash.Changeset.for_create(
          :create_generating_assistant,
          %{chat_id: chat.id, parent_id: user_message.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      queued_message =
        QueuedMessage
        |> Ash.Changeset.for_create(
          :enqueue,
          %{
            chat_id: chat.id,
            kind: :steer,
            target_generation_message_id: generation.id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      if status == :delivered do
        queued_message
        |> Ash.Changeset.for_update(
          :update_state,
          %{status: :delivered, finished_at: DateTime.utc_now()},
          actor: actor,
          authorize?: false
        )
        |> Ash.update!(actor: actor, authorize?: false)
      end

      chat
      |> Ash.Changeset.for_update(
        :set_last_message,
        %{last_message_id: user_message.id},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      Ash.destroy!(generation, actor: actor)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(QueuedMessage, queued_message.id, authorize?: false)
    end
  end

  defp create_chat!(actor) do
    Chat
    |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
    |> Ash.create!(actor: actor)
  end
end
