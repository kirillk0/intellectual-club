defmodule IntellectualClub.Chat.LinkedForkCleanupTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatMessageStepRequestFile
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Llm.LlmUsageRecord

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor, source: anchor!(actor)}
  end

  test "private anchors cannot be mass assigned or changed", %{actor: actor, source: source} do
    refute Ash.Resource.Info.attribute(Chat, :fork_task).public?
    refute Ash.Resource.Info.attribute(Chat, :fork_source_step_id).public?

    assert {:error, _} =
             Chat
             |> Ash.Changeset.for_create(
               :create_empty,
               %{
                 fork_source_step_id: source.step.id,
                 fork_task: "private"
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    child = linked_chat!(source, actor)

    assert {:error, _} =
             child
             |> Ash.Changeset.for_update(:update, %{fork_task: "changed"}, actor: actor)
             |> Ash.update(actor: actor)

    assert {:error, _} =
             child
             |> Ash.Changeset.for_update(:update, %{}, actor: actor)
             |> Ash.Changeset.force_change_attribute(:fork_source_step_id, nil)
             |> Ash.update(actor: actor)
  end

  test "forced anchors must agree on owner, message and selected source step", %{
    actor: actor,
    source: source
  } do
    other = anchor!(actor)
    %{user: stranger} = user_fixture()
    foreign = anchor!(stranger)

    for attrs <- [
          %{parent_chat_id: other.chat.id},
          %{parent_message_id: other.message.id},
          %{parent_tool_call_item_id: other.item.id},
          %{fork_source_step_id: other.step.id},
          %{parent_relation_kind: :spawn},
          %{fork_source_step_id: foreign.step.id}
        ] do
      assert {:error, _} = create_linked(source, actor, attrs)
    end

    assert {:error, _} = create_linked(source, stranger)
    assert {:error, _} = create_linked(source, actor, %{fork_task: nil})
    assert linked_chat!(source, actor).fork_task == "Investigate the selected call"
  end

  test "source step deletion removes nested live forks but preserves legacy and siblings", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    child_anchor = anchor!(actor, child)
    grandchild = linked_chat!(child_anchor, actor)
    _grandchild_anchor = anchor!(actor, grandchild)
    sibling_source = anchor!(actor, source.chat)
    sibling = linked_chat!(sibling_source, actor)
    legacy = legacy_chat!(source, actor)

    assert :ok = Ash.destroy(source.step, actor: actor)
    assert_missing(Chat, child.id, actor)
    assert_missing(Chat, grandchild.id, actor)
    assert_missing(ChatMessage, child_anchor.message.id, actor)
    assert_missing(ChatMessageStep, source.step.id, actor)
    assert Ash.get!(Chat, sibling.id, actor: actor).fork_source_step_id == sibling_source.step.id
    assert Ash.get!(Chat, legacy.id, actor: actor).fork_source_step_id == nil
    assert Ash.get!(ChatMessage, source.message.id, actor: actor).chat_id == source.chat.id
  end

  test "source message deletion clears last_message and detaches legacy copies", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    _child_anchor = anchor!(actor, child)
    legacy = legacy_chat!(source, actor)

    assert :ok = Ash.destroy(source.message, actor: actor)
    assert_missing(Chat, child.id, actor)
    assert Ash.get!(Chat, source.chat.id, actor: actor).last_message_id == nil
    assert Ash.get!(Chat, legacy.id, actor: actor).parent_message_id == nil
    assert Ash.get!(Chat, legacy.id, actor: actor).parent_chat_id == source.chat.id
  end

  test "source chat deletion clears both parent references without destroying legacy chats", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    _child_anchor = anchor!(actor, child)
    legacy = legacy_chat!(source, actor)
    legacy_anchor = anchor!(actor, legacy)

    assert :ok = Ash.destroy(source.chat, actor: actor)
    assert_missing(Chat, child.id, actor)
    assert_missing(Chat, source.chat.id, actor)
    legacy = Ash.get!(Chat, legacy.id, actor: actor)
    assert legacy.parent_chat_id == nil
    assert legacy.parent_message_id == nil
    assert Ash.get!(ChatMessageStep, legacy_anchor.step.id, actor: actor)
  end

  test "deleting a once-shared source preserves foreign legacy copies and removes dangling bookmarks",
       %{
         actor: actor,
         source: source
       } do
    %{user: recipient} = user_fixture()

    # Model references left by an old share after access to the source was revoked.
    legacy =
      legacy_chat!(source, actor)
      |> Ash.Changeset.for_update(:update, %{}, actor: actor)
      |> Ash.Changeset.force_change_attribute(:owner_id, recipient.id)
      |> Ash.update!(actor: actor)

    bookmark =
      IntellectualClub.Chat.MessageBookmark
      |> Ash.Changeset.for_create(:create, %{chat_message_id: source.message.id}, actor: actor)
      |> Ash.Changeset.force_change_attribute(:owner_id, recipient.id)
      |> Ash.create!(actor: actor)

    Ash.destroy!(source.chat, actor: actor)
    retained = Ash.get!(Chat, legacy.id, actor: recipient)
    assert retained.owner_id == recipient.id
    assert retained.parent_chat_id == nil
    assert retained.parent_message_id == nil
    assert_missing(IntellectualClub.Chat.MessageBookmark, bookmark.id, recipient)
  end

  test "retry replacement removes a fork whose anchor was deleted", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    nested_source = anchor!(actor, child)
    nested = linked_chat!(nested_source, actor)

    replacement = Persistence.replace_steps_for_retry!(source.message.id, 1, %{"retry" => true})
    assert is_integer(replacement)
    refute replacement == source.step.id
    assert_missing(Chat, child.id, actor)
    assert_missing(Chat, nested.id, actor)

    assert Ash.get!(ChatMessageStep, replacement, actor: actor).chat_message_id ==
             source.message.id
  end

  test "billing survives deletion with costs and snapshots intact and live FKs nilified", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    child_anchor = anchor!(actor, child)
    source_usage = usage!(source, actor)
    child_usage = usage!(child_anchor, actor)
    Ash.destroy!(source.step, actor: actor)

    retained_source = Ash.get!(LlmUsageRecord, source_usage.id, actor: actor)
    assert retained_source.chat_message_step_id == nil
    assert retained_source.chat_message_id == source.message.id
    assert retained_source.chat_id == source.chat.id
    retained_child = Ash.get!(LlmUsageRecord, child_usage.id, actor: actor)
    assert retained_child.chat_id == nil
    assert retained_child.chat_message_id == nil
    assert retained_child.chat_message_step_id == nil

    for {retained, original} <- [{retained_source, source_usage}, {retained_child, child_usage}] do
      for field <- [
            :cost,
            :input_tokens,
            :output_tokens,
            :raw_usage,
            :chat_id_snapshot,
            :chat_message_id_snapshot,
            :chat_message_step_id_snapshot
          ] do
        assert Map.fetch!(retained, field) == Map.fetch!(original, field)
      end
    end
  end

  test "descendants release request files without deleting independent files", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    child_anchor = anchor!(actor, child)
    {:ok, independent_file} = Files.create_from_binary("source.png", "image/png", "fork-cleanup")
    {:ok, request_file} = Files.duplicate_file(independent_file.id)

    binding =
      ChatMessageStepRequestFile
      |> Ash.Changeset.for_create(:create, %{
        chat_message_step_id: child_anchor.step.id,
        file_id: request_file.id,
        reference_key: request_file.external_id,
        source_file_external_id: independent_file.external_id,
        variant_key: "original"
      })
      |> Ash.create!()

    Ash.destroy!(source.step, actor: actor)
    assert_missing(ChatMessageStepRequestFile, binding.id, actor)
    assert_missing(StoredFile, request_file.id, actor)
    assert Ash.get!(StoredFile, independent_file.id, authorize?: false)
    assert :ok = Files.delete_file_and_maybe_payload(independent_file.id)
  end

  test "task envelopes retain history but lose source and target FKs", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    _child_anchor = anchor!(actor, child)
    task = background_task!(source, child, actor, :completed)
    Ash.destroy!(source.chat, actor: actor)
    retained = Ash.get!(BackgroundTask, task.id, actor: actor)
    assert retained.status == :completed

    for field <- [
          :source_chat_id,
          :source_message_id,
          :source_step_id,
          :source_tool_call_item_id,
          :lifecycle_message_id,
          :target_chat_id
        ] do
      assert Map.fetch!(retained, field) == nil
    end

    assert retained.runner_ref == task.runner_ref
  end

  test "completed generation events and bookmarks cannot block a linked child deletion", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    child_anchor = anchor!(actor, child)

    {:ok, event} =
      IntellectualClub.Notifications.record_generation_finished(child_anchor.message.id, :done)

    bookmark =
      IntellectualClub.Chat.MessageBookmark
      |> Ash.Changeset.for_create(:create, %{chat_message_id: child_anchor.message.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    %{user: stranger} = user_fixture()

    event_projection =
      Ash.get!(IntellectualClub.Chat.LinkedForkCleanup.GenerationEvent, event.id, actor: actor)

    assert {:error, _} = Ash.destroy(event_projection, actor: stranger)

    Ash.destroy!(source.step, actor: actor)
    assert_missing(Chat, child.id, actor)
    assert_missing(IntellectualClub.Notifications.WebPushGenerationEvent, event.id, actor)
    assert_missing(IntellectualClub.Chat.MessageBookmark, bookmark.id, actor)
  end

  test "only an owner may destroy a fork source", %{actor: actor, source: source} do
    child = linked_chat!(source, actor)
    %{user: stranger} = user_fixture()
    assert {:error, _} = Ash.destroy(source.step, actor: stranger)
    assert Ash.get!(Chat, child.id, actor: actor)
  end

  test "cyclic legacy parent chains cannot become live fork history", %{
    actor: actor,
    source: source
  } do
    source.chat
    |> Ash.Changeset.for_update(:update, %{parent_chat_id: source.chat.id}, actor: actor)
    |> Ash.update!(actor: actor)

    assert {:error, _} = create_linked(source, actor)
  end

  test "corrupt linked cycles fail closed without recursive deletion", %{
    actor: actor,
    source: source
  } do
    child = linked_chat!(source, actor)
    inner = anchor!(actor, child)

    IntellectualClub.Chat.ForkHistoryCorruptFixture
    |> Ash.get!(source.chat.id,
      actor: actor,
      domain: IntellectualClub.Chat.ForkHistoryFixtureDomain
    )
    |> Ash.Changeset.for_update(
      :corrupt_anchor,
      %{
        parent_chat_id: child.id,
        parent_message_id: inner.message.id,
        parent_tool_call_item_id: inner.item.id,
        fork_source_step_id: inner.step.id,
        fork_task: "cycle",
        parent_relation_kind: :fork
      },
      actor: actor,
      domain: IntellectualClub.Chat.ForkHistoryFixtureDomain
    )
    |> Ash.update!(actor: actor, domain: IntellectualClub.Chat.ForkHistoryFixtureDomain)

    assert {:error, error} = Ash.destroy(source.step, actor: actor)
    assert Exception.message(error) =~ "Cycle in linked fork"
    assert Ash.get!(Chat, child.id, actor: actor)
    assert Ash.get!(Chat, source.chat.id, actor: actor)
    assert Ash.get!(ChatMessageStep, source.step.id, actor: actor)
  end

  defp anchor!(actor, chat \\ nil) do
    chat = chat || create_chat!(actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(:add_message, %{chat_id: chat.id, role: :assistant},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(:create, %{chat_message_id: message.id, sequence: 1},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: 1,
          type: :tool_call
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    %{chat: chat, message: message, step: step, item: item}
  end

  defp create_chat!(actor, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp legacy_chat!(source, actor) do
    create_chat!(actor, %{
      parent_chat_id: source.chat.id,
      parent_message_id: source.message.id,
      parent_relation_kind: :fork,
      subagent: true
    })
  end

  defp linked_chat!(source, actor) do
    {:ok, chat} = create_linked(source, actor)
    chat
  end

  defp create_linked(source, actor, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          parent_chat_id: source.chat.id,
          parent_message_id: source.message.id,
          parent_tool_call_item_id: source.item.id,
          parent_relation_kind: :fork,
          subagent: true,
          fork_source_step_id: source.step.id,
          fork_task: "Investigate the selected call"
        },
        overrides
      )

    {private, public} = Map.split(attrs, [:fork_source_step_id, :fork_task])

    Chat
    |> Ash.Changeset.for_create(:create_empty, public, actor: actor)
    |> Ash.Changeset.force_change_attributes(private)
    |> Ash.create(actor: actor)
  end

  defp usage!(anchor, actor) do
    LlmUsageRecord
    |> Ash.Changeset.for_create(
      :create,
      %{
        usage_user_id: actor.id,
        usage_user_id_snapshot: actor.id,
        usage_username_snapshot: actor.username,
        configuration_owner_id_snapshot: actor.id,
        llm_configuration_id_snapshot: 1,
        llm_configuration_label_snapshot: "Original paid configuration",
        chat_id: anchor.chat.id,
        chat_id_snapshot: anchor.chat.id,
        chat_message_id: anchor.message.id,
        chat_message_id_snapshot: anchor.message.id,
        chat_message_step_id: anchor.step.id,
        chat_message_step_id_snapshot: anchor.step.id,
        step_sequence: 1,
        occurred_at: DateTime.utc_now(),
        cost: 0.25,
        input_tokens: 200,
        output_tokens: 100,
        raw_usage: %{"billed_cost" => 0.25}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp background_task!(source, target, actor, status) do
    BackgroundTask
    |> Ash.Changeset.for_create(
      :create,
      %{
        kind: "fork",
        adapter: "cleanup_test",
        function_name: "fork",
        status: status,
        source_chat_id: source.chat.id,
        source_message_id: source.message.id,
        lifecycle_message_id: source.message.id,
        source_step_id: source.step.id,
        source_tool_call_item_id: source.item.id,
        target_chat_id: target.id,
        runner_ref: %{"original_target" => target.id}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp assert_missing(resource, id, actor) do
    assert {:error, %Ash.Error.Invalid{}} = Ash.get(resource, id, actor: actor)
  end
end
