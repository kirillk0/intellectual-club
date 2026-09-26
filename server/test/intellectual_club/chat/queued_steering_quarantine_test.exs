defmodule IntellectualClub.Chat.QueuedSteeringQuarantineTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.QueueCoordinator

  setup do
    %{user: actor} = user_fixture()
    {chat, generation} = create_generation!(actor)
    %{actor: actor, chat: chat, generation: generation}
  end

  test "rejects only matching pending snapshots once, leaving new and unrelated entries alone", %{
    actor: actor,
    chat: chat,
    generation: generation
  } do
    entries =
      for text <- ["Reject", "Edited", "Canceled", "Deleted", "Delivered"] do
        {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, text, actor)
        queued
      end

    [rejected, edited, canceled, deleted, delivered] = entries
    {_other_chat, other_generation} = create_generation!(actor)
    {:ok, other} = QueuedMessages.enqueue_steer(other_generation.id, "Other target", actor)
    {:ok, follow_up} = QueuedMessages.enqueue_follow_up(chat.id, %{content: "Follow-up"}, actor)
    specs = Enum.map(entries ++ [other, follow_up, rejected], &snapshot/1)

    assert {:ok, _edited} = QueuedMessages.update(edited.id, %{content: "Replacement"}, actor)
    assert {:ok, _canceled} = QueuedMessages.cancel(canceled.id, actor)
    Ash.destroy!(deleted, actor: actor)
    assert {:ok, _delivered} = QueuedMessages.mark_delivered(delivered, %{}, actor)
    {:ok, new} = QueuedMessages.enqueue_steer(generation.id, "Reject", actor)

    rejected_id = rejected.id
    assert {:ok, [^rejected_id]} = QueuedMessages.reject_steers(generation.id, specs, actor)
    blocked = assert_quarantined!(rejected.id, actor)
    assert blocked.attempt_count == 1
    assert {:ok, []} = QueuedMessages.reject_steers(generation.id, specs, actor)
    repeated = assert_quarantined!(rejected.id, actor)
    assert repeated.attempt_count == 1
    assert repeated.updated_at == blocked.updated_at

    for queued <- [edited, new, other, follow_up] do
      assert {:ok, %{status: :pending, attempt_count: 0}} = QueuedMessages.get(queued.id, actor)
    end

    assert {:ok, %{status: :canceled}} = QueuedMessages.get(canceled.id, actor)
    assert {:ok, %{status: :delivered}} = QueuedMessages.get(delivered.id, actor)
    assert {:error, :not_found} = QueuedMessages.get(deleted.id, actor)
  end

  test "an in-flight rejection cannot quarantine an edited-and-restored snapshot", %{
    actor: actor,
    generation: generation
  } do
    {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, "Original", actor)
    spec = snapshot(queued)
    assert {:ok, _edited} = QueuedMessages.update(queued.id, %{content: "Changed"}, actor)
    assert {:ok, restored} = QueuedMessages.update(queued.id, %{content: "Original"}, actor)
    assert DateTime.compare(restored.updated_at, queued.updated_at) == :gt

    assert {:ok, []} = QueuedMessages.reject_steers(generation.id, [spec], actor)
    assert {:ok, %{status: :pending, attempt_count: 0}} = QueuedMessages.get(queued.id, actor)

    id = queued.id

    assert {:ok, [^id]} =
             QueuedMessages.reject_steers(generation.id, [snapshot(restored)], actor)
  end

  test "snapshots without a revision still require the exact id and text", %{
    actor: actor,
    generation: generation
  } do
    {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, " Keep spacing ", actor)

    assert {:ok, []} =
             QueuedMessages.reject_steers(
               generation.id,
               [%{id: queued.id, text: "Keep spacing"}],
               actor
             )

    id = queued.id

    assert {:ok, [^id]} =
             QueuedMessages.reject_steers(
               generation.id,
               [%{id: queued.id, text: " Keep spacing "}],
               actor
             )
  end

  test "rejection requires an owner actor and an active assistant target", %{
    actor: actor,
    generation: generation
  } do
    %{user: outsider} = user_fixture()
    {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, "Private", actor)
    specs = [snapshot(queued)]

    assert {:error, :forbidden} = QueuedMessages.reject_steers(generation.id, specs, nil)
    assert {:error, :forbidden} = QueuedMessages.reject_steers(generation.id, specs, %{})
    assert {:error, _reason} = QueuedMessages.reject_steers(generation.id, specs, outsider)

    assert {:error, :invalid_steering_specs} =
             QueuedMessages.reject_steers(generation.id, [%{id: queued.id}], actor)

    assert {:ok, %{status: :pending, attempt_count: 0}} = QueuedMessages.get(queued.id, actor)
    set_status!(generation, :done, actor)

    assert {:error, :generation_not_active} =
             QueuedMessages.reject_steers(generation.id, specs, actor)

    assert {:ok, %{status: :pending, attempt_count: 0}} = QueuedMessages.get(queued.id, actor)
  end

  test "quarantined steering stays visible, editable and removable without resuming", %{
    actor: actor,
    chat: chat,
    generation: generation
  } do
    queued = quarantine!(generation, actor)
    assert {:ok, [visible]} = QueuedMessages.list_for_chat(chat.id, actor)
    assert visible.id == queued.id
    assert {:ok, []} = QueuedMessages.list_pending_steers(generation.id, actor)

    assert {:ok, edited} =
             QueuedMessages.update(queued.id, %{content: "Fixed instruction"}, actor)

    assert edited.status == :blocked
    assert edited.blocked_reason == "steering_failed"
    assert edited.attempt_count == 1
    assert DateTime.compare(edited.updated_at, queued.updated_at) == :gt

    assert QueuedMessages.content_specs(edited) == [
             %{kind: :text, content_text: "Fixed instruction"}
           ]

    assert {:ok, []} = QueuedMessages.list_pending_steers(generation.id, actor)

    assert {:ok, %{status: :canceled, contents: []}} = QueuedMessages.cancel(queued.id, actor)
    assert {:ok, []} = QueuedMessages.list_for_chat(chat.id, actor)
  end

  test "explicit active retry preserves identity and invalidates the in-flight rejection", %{
    actor: actor,
    chat: chat,
    generation: generation
  } do
    {:ok, _head} = QueuedMessages.enqueue_follow_up(chat.id, %{content: "Head"}, actor)
    untouched = quarantine!(generation, actor)
    {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, "Retry this", actor)
    spec = snapshot(queued)
    assert {:ok, [_]} = QueuedMessages.reject_steers(generation.id, [spec], actor)
    blocked = assert_quarantined!(queued.id, actor)
    %{user: outsider} = user_fixture()

    assert {:error, _reason} = QueuedMessages.send_next(queued.id, outsider)
    assert {:ok, retried} = QueuedMessages.send_next(queued.id, actor)
    assert retried.id == queued.id
    assert retried.chat_id == chat.id
    assert retried.kind == :steer
    assert retried.status == :pending
    assert retried.target_generation_message_id == generation.id
    assert retried.blocked_reason == nil
    assert retried.attempt_count == 1
    assert DateTime.compare(retried.updated_at, blocked.updated_at) == :gt
    assert QueuedMessages.content_specs(retried) == [%{kind: :text, content_text: "Retry this"}]

    assert {:ok, []} = QueuedMessages.reject_steers(generation.id, [spec], actor)
    assert {:ok, [pending]} = QueuedMessages.list_pending_steers(generation.id, actor)
    assert pending.id == queued.id
    assert_quarantined!(untouched.id, actor)
    assert {:error, :queued_steering_changed} = QueuedMessages.send_next(queued.id, actor)

    assert {:ok, [_]} = QueuedMessages.reject_steers(generation.id, [snapshot(retried)], actor)
    assert assert_quarantined!(queued.id, actor).attempt_count == 2
  end

  test "send-next does not retry a steer blocked for another reason", %{
    actor: actor,
    generation: generation
  } do
    {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, "Not quarantined", actor)
    assert {:error, :queued_steering_changed} = QueuedMessages.send_next(queued.id, actor)
    assert {:ok, _blocked} = QueuedMessages.mark_blocked(queued, :other_reason, actor)
    assert {:error, :queued_steering_changed} = QueuedMessages.send_next(queued.id, actor)
  end

  for {terminal_status, retry_status, retry_reason} <- [
        {:done, :pending, nil},
        {:error, :blocked, "generation_error"},
        {:canceled, :blocked, "generation_canceled"}
      ] do
    @terminal_status terminal_status
    @retry_status retry_status
    @retry_reason retry_reason

    test "quarantine survives #{@terminal_status} and only explicit retry converts it", %{
      actor: actor,
      chat: chat,
      generation: generation
    } do
      queued = quarantine!(generation, actor)
      set_status!(generation, @terminal_status, actor)

      assert {:ok, %{converted_steers: 0}} =
               QueueCoordinator.settle_generation(generation.id, @terminal_status)

      assert :empty = QueueCoordinator.prepare_next(chat.id)
      refute chat.id in QueueCoordinator.ready_chat_ids()
      assert_quarantined!(queued.id, actor)

      assert {:ok, retried} = QueuedMessages.send_next(queued.id, actor)
      assert retried.id == queued.id
      assert retried.chat_id == chat.id
      assert retried.kind == :follow_up
      assert retried.status == @retry_status
      assert retried.blocked_reason == @retry_reason
      assert retried.anchor_message_id == generation.id
      assert retried.target_generation_message_id == nil
      assert retried.attempt_count == 1
      assert retried.contents != []
    end
  end

  test "a generation retry and ordinary follow-up send never resume quarantined steering", %{
    actor: actor,
    chat: chat,
    generation: generation
  } do
    queued = quarantine!(generation, actor)
    set_status!(generation, :error, actor)
    assert {:ok, _} = QueueCoordinator.settle_generation(generation.id, :error)
    set_status!(generation, :generating, actor)
    assert Ash.get!(ChatMessage, generation.id, actor: actor).status == :generating
    assert {:ok, []} = QueuedMessages.list_pending_steers(generation.id, actor)
    set_status!(generation, :done, actor)

    assert {:ok, %{converted_steers: 0}} =
             QueueCoordinator.settle_generation(generation.id, :done)

    assert :ok = QueueCoordinator.ensure_direct_start_allowed(chat.id)

    assert {:ok, follow_up} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "New turn"}, actor)

    assert {:ok, _pending} = QueuedMessages.send_next(follow_up.id, actor)
    assert_quarantined!(queued.id, actor)
    assert {:ok, []} = QueuedMessages.list_pending_steers(generation.id, actor)
  end

  test "quarantined steering does not block direct continuation or enter its request", %{
    actor: actor,
    chat: chat,
    generation: generation
  } do
    queued = quarantine!(generation, actor)
    set_status!(generation, :done, actor)
    assert {:ok, _} = QueueCoordinator.settle_generation(generation.id, :done)
    assert :ok = QueueCoordinator.ensure_direct_start_allowed(chat.id)
    assert {:ok, context} = QueueCoordinator.prepare_direct_generation(chat.id, actor: actor)
    assert context.message_id != generation.id
    refute Jason.encode!(context.request_payload) =~ "Rejected instruction"
    assert_quarantined!(queued.id, actor)
  end

  test "pending commands and non-steering-failure blocks still prevent direct continuation", %{
    actor: actor,
    chat: chat,
    generation: generation
  } do
    {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, "Pending instruction", actor)
    assert {:error, :queue_not_empty} = QueueCoordinator.ensure_direct_start_allowed(chat.id)
    assert {:ok, _} = QueuedMessages.mark_blocked(queued.id, "another_reason", actor)
    assert {:error, :queue_not_empty} = QueueCoordinator.ensure_direct_start_allowed(chat.id)
  end

  test "handoff transfers ordinary backlog but leaves quarantined steering in the source", %{
    actor: actor,
    chat: chat,
    generation: generation
  } do
    queued = quarantine!(generation, actor)
    {:ok, follow_up} = QueuedMessages.enqueue_follow_up(chat.id, %{content: "Transfer"}, actor)
    {:ok, pending_steer} = QueuedMessages.enqueue_steer(generation.id, "Late steer", actor)
    {child, child_generation} = create_handoff!(chat, generation, actor)
    set_status!(generation, :done, actor)

    assert {:ok, %{transferred_count: 2}} =
             QueueCoordinator.transfer_to_handoff(generation.id, child.id, child_generation.id)

    assert {:ok, %{transferred_count: 0}} =
             QueueCoordinator.prepare_terminal_handoff(generation.id, child.id)

    assert {:ok, [remaining]} = QueuedMessages.list_for_chat(chat.id, actor)
    assert remaining.id == queued.id
    assert_quarantined!(queued.id, actor)
    assert {:ok, transferred} = QueuedMessages.list_for_chat(child.id, actor)
    assert Enum.map(transferred, & &1.id) == [follow_up.id, pending_steer.id]
    assert Enum.all?(transferred, &(&1.kind == :follow_up and &1.status == :pending))
  end

  for {child_status, retry_status, retry_reason} <- [
        {:generating, :pending, nil},
        {:done, :pending, nil},
        {:error, :blocked, "generation_error"},
        {:canceled, :blocked, "generation_canceled"}
      ] do
    @child_status child_status
    @child_retry_status retry_status
    @child_retry_reason retry_reason

    test "explicit retry routes to the #{@child_status} handoff child with terminal semantics", %{
      actor: actor,
      chat: chat,
      generation: generation
    } do
      queued = quarantine!(generation, actor)
      {child, child_generation} = create_handoff!(chat, generation, actor)
      set_status!(generation, :done, actor)
      set_status!(child_generation, @child_status, actor)

      assert {:ok, retried} = QueuedMessages.send_next(queued.id, actor)
      assert retried.id == queued.id
      assert retried.chat_id == child.id
      assert retried.kind == :follow_up
      assert retried.status == @child_retry_status
      assert retried.blocked_reason == @child_retry_reason
      assert retried.anchor_message_id == child_generation.id
      assert retried.target_generation_message_id == nil
      assert {:ok, []} = QueuedMessages.list_for_chat(chat.id, actor)
      assert {:ok, [listed]} = QueuedMessages.list_for_chat(child.id, actor)
      assert listed.id == queued.id
    end
  end

  test "retry after an uncommitted canceled handoff stays blocked in the source", %{
    actor: actor,
    chat: chat,
    generation: generation
  } do
    queued = quarantine!(generation, actor)
    {child, _child_generation} = create_handoff!(chat, generation, actor)
    set_status!(generation, :canceled, actor)

    assert {:ok, retried} = QueuedMessages.send_next(queued.id, actor)
    assert retried.id == queued.id
    assert retried.chat_id == chat.id
    assert retried.kind == :follow_up
    assert retried.status == :blocked
    assert retried.blocked_reason == "generation_canceled"
    assert {:ok, []} = QueuedMessages.list_for_chat(child.id, actor)
  end

  defp snapshot(queued) do
    text =
      queued
      |> QueuedMessages.content_specs()
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.map_join("", & &1.content_text)

    %{id: queued.id, text: text, updated_at: queued.updated_at}
  end

  defp quarantine!(generation, actor) do
    {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, "Rejected instruction", actor)
    assert {:ok, [_]} = QueuedMessages.reject_steers(generation.id, [snapshot(queued)], actor)
    assert_quarantined!(queued.id, actor)
  end

  defp assert_quarantined!(id, actor) do
    assert {:ok, queued} = QueuedMessages.get(id, actor)
    assert queued.kind == :steer
    assert queued.status == :blocked
    assert queued.blocked_reason == "steering_failed"
    assert queued.contents != []
    assert queued.steering_item_id == nil
    queued
  end

  defp create_handoff!(chat, generation, actor) do
    create_generation!(actor, %{
      parent_chat_id: chat.id,
      parent_message_id: generation.id,
      parent_relation_kind: :handoff,
      subagent: true
    })
  end

  defp create_generation!(actor, attrs \\ %{}) do
    chat =
      Chat
      |> Ash.Changeset.for_create(:create, Map.merge(%{note: ""}, attrs), actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

    generation =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: root.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {chat, generation}
  end

  defp set_status!(generation, status, actor) do
    ChatMessage
    |> Ash.get!(generation.id, actor: actor)
    |> Ash.Changeset.for_update(
      :set_generation_state,
      %{
        status: status,
        finished_at: if(status == :generating, do: nil, else: DateTime.utc_now())
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end
end
