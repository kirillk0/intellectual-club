defmodule IntellectualClub.Chat.LinkedForkCleanupTest do
  @moduledoc """
  Behaviour of linked fork cleanup: anchor integrity, what deleting a fork
  source removes or preserves, keep-children deletion, the cleanup plan
  (deletions vs fences), the operation capability and fail-closed cycles.

  Real commit/rollback semantics and lock ordering live in
  `LinkedForkCleanupTransactionsTest`; query budgets in
  `LinkedForkCleanupPerformanceTest`.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Chat.ForkFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatMessageStepRequestFile
  alias IntellectualClub.Chat.ForkHistory
  alias IntellectualClub.Chat.LinkedForkCleanup
  alias IntellectualClub.Chat.LinkedForkCleanup.Operation
  alias IntellectualClub.Chat.LinkedForkCleanup.Plan
  alias IntellectualClub.Chat.LinkedForkCleanupLocks, as: Locks
  alias IntellectualClub.Chat.LinkedForkCleanupLocksHelper, as: LocksHelper
  alias IntellectualClub.Chat.MessageBookmark
  alias IntellectualClub.SqlCapture
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Llm.LlmUsageRecord

  require Ash.Query

  @cycle "Cycle in linked fork cleanup dependencies"
  @owner_only "Only the owner can lock linked fork cleanup dependencies"
  @changed "Linked fork cleanup dependencies changed; retry the transaction"

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor, source: create_tool_call_anchor!(actor)}
  end

  describe "linked fork anchors" do
    test "private anchors cannot be mass assigned or changed", %{actor: actor, source: source} do
      refute Ash.Resource.Info.attribute(Chat, :fork_task).public?
      refute Ash.Resource.Info.attribute(Chat, :fork_source_step_id).public?

      assert {:error, _} =
               Chat
               |> Ash.Changeset.for_create(
                 :create_empty,
                 %{fork_source_step_id: source.step.id, fork_task: "private"},
                 actor: actor
               )
               |> Ash.create(actor: actor)

      child = create_linked_chat!(actor, source)

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
      other = create_tool_call_anchor!(actor)
      %{user: stranger} = user_fixture()
      foreign = create_tool_call_anchor!(stranger)

      for {linker, attrs} <- [
            {actor, %{parent_chat_id: other.chat.id}},
            {actor, %{parent_message_id: other.message.id}},
            {actor, %{parent_tool_call_item_id: other.item.id}},
            {actor, %{fork_source_step_id: other.step.id}},
            {actor, %{parent_relation_kind: :spawn}},
            {actor, %{fork_source_step_id: foreign.step.id}},
            {actor, %{fork_task: nil}},
            {stranger, %{}}
          ] do
        assert {:error, _} = link(linker, source, attrs), inspect(attrs)
      end

      assert create_linked_chat!(actor, source, fork_task: "Selected call").fork_task ==
               "Selected call"
    end
  end

  describe "deleting a fork source" do
    test "step deletion removes nested live forks but preserves legacy copies and siblings", %{
      actor: actor,
      source: source
    } do
      child = create_linked_chat!(actor, source)
      child_anchor = create_tool_call_anchor!(actor, chat: child)
      grandchild = create_linked_chat!(actor, child_anchor)
      _grandchild_anchor = create_tool_call_anchor!(actor, chat: grandchild)
      sibling_source = create_tool_call_anchor!(actor, chat: source.chat)
      sibling = create_linked_chat!(actor, sibling_source)
      legacy = create_legacy_fork!(actor, source)

      assert :ok = Ash.destroy(source.step, actor: actor)
      assert_missing!(Chat, child.id, actor)
      assert_missing!(Chat, grandchild.id, actor)
      assert_missing!(ChatMessage, child_anchor.message.id, actor)
      assert_missing!(ChatMessageStep, source.step.id, actor)

      assert Ash.get!(Chat, sibling.id, actor: actor).fork_source_step_id ==
               sibling_source.step.id

      assert Ash.get!(Chat, legacy.id, actor: actor).fork_source_step_id == nil
      assert Ash.get!(ChatMessage, source.message.id, actor: actor).chat_id == source.chat.id
    end

    test "message deletion clears last_message and detaches legacy copies", %{
      actor: actor,
      source: source
    } do
      child = create_linked_chat!(actor, source)
      _child_anchor = create_tool_call_anchor!(actor, chat: child)
      legacy = create_legacy_fork!(actor, source)

      assert :ok = Ash.destroy(source.message, actor: actor)
      assert_missing!(Chat, child.id, actor)
      assert Ash.get!(Chat, source.chat.id, actor: actor).last_message_id == nil
      legacy = Ash.get!(Chat, legacy.id, actor: actor)
      assert legacy.parent_message_id == nil
      assert legacy.parent_chat_id == source.chat.id
    end

    test "chat deletion clears both parent references without destroying legacy chats", %{
      actor: actor,
      source: source
    } do
      child = create_linked_chat!(actor, source)
      _child_anchor = create_tool_call_anchor!(actor, chat: child)
      legacy = create_legacy_fork!(actor, source)
      legacy_anchor = create_tool_call_anchor!(actor, chat: legacy)

      assert :ok = Ash.destroy(source.chat, actor: actor)
      assert_missing!(Chat, child.id, actor)
      assert_missing!(Chat, source.chat.id, actor)
      legacy = Ash.get!(Chat, legacy.id, actor: actor)
      assert legacy.parent_chat_id == nil
      assert legacy.parent_message_id == nil
      assert Ash.get!(ChatMessageStep, legacy_anchor.step.id, actor: actor)
    end

    test "a once-shared source keeps foreign legacy copies and drops dangling bookmarks", %{
      actor: actor,
      source: source
    } do
      %{user: recipient} = user_fixture()

      # Model references left by an old share after access to the source was revoked.
      legacy =
        force_update!(actor, create_legacy_fork!(actor, source), %{owner_id: recipient.id})

      bookmark =
        MessageBookmark
        |> Ash.Changeset.for_create(:create, %{chat_message_id: source.message.id}, actor: actor)
        |> Ash.Changeset.force_change_attribute(:owner_id, recipient.id)
        |> Ash.create!(actor: actor)

      Ash.destroy!(source.chat, actor: actor)
      retained = Ash.get!(Chat, legacy.id, actor: recipient)
      assert retained.owner_id == recipient.id
      assert retained.parent_chat_id == nil
      assert retained.parent_message_id == nil
      assert_missing!(MessageBookmark, bookmark.id, recipient)
    end

    test "retry replacement removes forks of the replaced step", %{actor: actor, source: source} do
      child = create_linked_chat!(actor, source)
      nested = create_linked_chat!(actor, create_tool_call_anchor!(actor, chat: child))

      replacement = Persistence.replace_steps_for_retry!(source.message.id, 1, %{"retry" => true})
      assert is_integer(replacement)
      refute replacement == source.step.id
      assert_missing!(Chat, child.id, actor)
      assert_missing!(Chat, nested.id, actor)

      assert Ash.get!(ChatMessageStep, replacement, actor: actor).chat_message_id ==
               source.message.id
    end

    test "billing survives with costs and snapshots intact and live references nilified", %{
      actor: actor,
      source: source
    } do
      child = create_linked_chat!(actor, source)
      child_anchor = create_tool_call_anchor!(actor, chat: child)
      source_usage = create_usage_record!(actor, source)
      child_usage = create_usage_record!(actor, child_anchor)
      Ash.destroy!(source.step, actor: actor)

      retained_source = Ash.get!(LlmUsageRecord, source_usage.id, actor: actor)
      assert retained_source.chat_message_step_id == nil
      assert retained_source.chat_message_id == source.message.id
      assert retained_source.chat_id == source.chat.id
      retained_child = Ash.get!(LlmUsageRecord, child_usage.id, actor: actor)
      assert retained_child.chat_id == nil
      assert retained_child.chat_message_id == nil
      assert retained_child.chat_message_step_id == nil

      for {retained, original} <- [{retained_source, source_usage}, {retained_child, child_usage}],
          field <- [
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

    test "descendants release request files without deleting independent files", %{
      actor: actor,
      source: source
    } do
      child_anchor = create_tool_call_anchor!(actor, chat: create_linked_chat!(actor, source))

      {:ok, independent_file} =
        Files.create_from_binary("source.png", "image/png", "fork-cleanup")

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
      assert_missing!(ChatMessageStepRequestFile, binding.id, actor)
      assert {:error, _} = Ash.get(StoredFile, request_file.id, authorize?: false)
      assert Ash.get!(StoredFile, independent_file.id, authorize?: false)
      assert :ok = Files.delete_file_and_maybe_payload(independent_file.id)
    end

    test "task envelopes retain history but lose source and target references", %{
      actor: actor,
      source: source
    } do
      child = create_linked_chat!(actor, source)
      _child_anchor = create_tool_call_anchor!(actor, chat: child)
      task = create_fork_task!(actor, source, child)
      Ash.destroy!(source.chat, actor: actor)
      retained = Ash.get!(BackgroundTask, task.id, actor: actor)
      assert retained.status == :completed
      assert retained.runner_ref == task.runner_ref

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
    end

    test "completed generation events and bookmarks cannot block a linked child deletion", %{
      actor: actor,
      source: source
    } do
      child = create_linked_chat!(actor, source)
      child_anchor = create_tool_call_anchor!(actor, chat: child)

      {:ok, event} =
        IntellectualClub.Notifications.record_generation_finished(child_anchor.message.id, :done)

      bookmark =
        MessageBookmark
        |> Ash.Changeset.for_create(:create, %{chat_message_id: child_anchor.message.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      %{user: stranger} = user_fixture()
      projection = Ash.get!(LinkedForkCleanup.GenerationEvent, event.id, actor: actor)
      assert {:error, _} = Ash.destroy(projection, actor: stranger)

      Ash.destroy!(source.step, actor: actor)
      assert_missing!(Chat, child.id, actor)
      assert_missing!(IntellectualClub.Notifications.WebPushGenerationEvent, event.id, actor)
      assert_missing!(MessageBookmark, bookmark.id, actor)
    end

    test "only an owner may destroy a fork source", %{actor: actor, source: source} do
      child = create_linked_chat!(actor, source)
      %{user: stranger} = user_fixture()
      assert {:error, _} = Ash.destroy(source.step, actor: stranger)
      assert Ash.get!(Chat, child.id, actor: actor)
    end
  end

  describe "deleting a message but keeping its children" do
    setup %{actor: actor} do
      chat = create_empty_chat!(actor)
      parent = fork_anchor!(actor, chat, nil)

      {:ok, deleted} =
        Threads.add_message(chat, :user, "Remove only this message",
          actor: actor,
          parent_id: parent.message.id
        )

      stale_chat = Ash.get!(Chat, chat.id, actor: actor)
      child = fork_anchor!(actor, chat, deleted.id)
      %{chat: stale_chat, parent: parent, deleted: deleted, child: child}
    end

    test "reparents children and keeps the surviving active leaf despite a stale chat", f do
      assert f.chat.last_message_id == f.deleted.id

      assert {:ok, branch} =
               Threads.delete_message_keep_children(f.chat, f.deleted.id, f.actor)

      assert Enum.map(branch, & &1.id) == [f.parent.message.id, f.child.message.id]
      assert_missing!(ChatMessage, f.deleted.id, f.actor)

      assert Ash.get!(ChatMessage, f.child.message.id, actor: f.actor).parent_id ==
               f.parent.message.id

      assert Ash.get!(Chat, f.chat.id, actor: f.actor).last_message_id == f.child.message.id
    end

    test "missing messages and role mixing return API errors without mutations", f do
      %{actor: actor, chat: chat, deleted: deleted} = f
      foreign_chat = create_empty_chat!(actor)
      before = tree_state!(chat, actor)

      assert {:error, :message_not_found} =
               Threads.delete_message_keep_children(chat.id, -1, actor)

      assert {:error, :message_not_found} =
               Threads.delete_message_keep_children(foreign_chat.id, deleted.id, actor)

      assert tree_state!(chat, actor) == before

      {:ok, _sibling} =
        Threads.add_message(chat, :user, "Another branch",
          actor: actor,
          parent_id: f.parent.message.id
        )

      before = tree_state!(chat, actor)

      assert {:error, :cannot_mix_roles} =
               Threads.delete_message_keep_children(chat.id, deleted.id, actor)

      assert tree_state!(chat, actor) == before
    end

    test "linked fork history is read-only: the active leaf and every reparent roll back", f do
      actor = f.actor
      linked = create_linked_chat!(actor, f.parent, fork_task: "Preserve inherited context")
      local_parent = fork_anchor!(actor, linked, nil)

      {:ok, deleted} =
        Threads.add_message(linked, :user, "Read-only local history",
          actor: actor,
          parent_id: local_parent.message.id
        )

      children = [
        fork_anchor!(actor, linked, deleted.id),
        fork_anchor!(actor, linked, deleted.id)
      ]

      linked
      |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: deleted.id}, actor: actor)
      |> Ash.update!(actor: actor)

      before = tree_state!(linked, actor)
      assert {:ok, [_]} = inherited = ForkHistory.prefix(linked, actor)
      delete = fn -> Threads.delete_message_keep_children(linked.id, deleted.id, actor) end

      for operation <- [delete, fn -> Ash.transaction(ChatMessage, delete) end] do
        assert {:error, %Ash.Error.Invalid{} = error} = operation.()
        assert Exception.message(error) =~ "Linked fork history is read-only"
        assert tree_state!(linked, actor) == before
        assert ForkHistory.prefix(linked, actor) == inherited

        for child <- children do
          assert Ash.get!(ChatMessage, child.message.id, actor: actor).parent_id == deleted.id
        end
      end
    end

    test "deleting a fork source keeps retained descendants and unrelated inherited history",
         f do
      %{actor: actor, parent: parent, deleted: deleted, child: child} = f
      dependent = create_linked_chat!(actor, parent)
      retained = create_linked_chat!(actor, child)
      unrelated = create_linked_chat!(actor, fork_anchor!(actor, create_empty_chat!(actor), nil))
      assert {:ok, [_]} = inherited = ForkHistory.prefix(unrelated, actor)
      assert {:ok, prefix} = ForkHistory.prefix(retained, actor)
      assert Enum.map(prefix, & &1.id) == [parent.message.id, deleted.id, child.message.id]

      assert {:ok, branch} =
               Threads.delete_message_keep_children(f.chat.id, parent.message.id, actor)

      assert Enum.map(branch, & &1.id) == [deleted.id, child.message.id]
      assert_missing!(Chat, dependent.id, actor)
      assert_missing!(ChatMessage, parent.message.id, actor)
      assert Ash.get!(ChatMessage, deleted.id, actor: actor).parent_id == nil
      assert Ash.get!(ChatMessage, child.message.id, actor: actor).parent_id == deleted.id
      assert {:ok, prefix} = ForkHistory.prefix(retained, actor)
      assert Enum.map(prefix, & &1.id) == [deleted.id, child.message.id]
      assert ForkHistory.prefix(unrelated, actor) == inherited
    end
  end

  describe "cleanup plan" do
    test "message, tree and keep-children scopes distinguish deletion from fences", %{
      actor: actor
    } do
      parent = anchor!(actor)
      source = anchor!(actor, parent.chat, parent.message.id)
      child = anchor!(actor, parent.chat, source.message.id)
      grandchild = anchor!(actor, parent.chat, child.message.id)
      sibling = anchor!(actor, parent.chat, parent.message.id)
      fork = anchor!(actor, create_linked_chat!(actor, source))
      child_fork = anchor!(actor, create_linked_chat!(actor, child))

      plain = prepare!({:message, source.message.id}, actor)
      kept = prepare!({:message_keep_children, source.message.id}, actor)
      tree = prepare!({:message_tree, source.message.id}, actor)

      for plan <- [plain, kept] do
        assert ids(plan.deleted.chats) == set([fork.chat.id])
        assert ids(plan.deleted.messages) == set([source.message.id, fork.message.id])
        assert ids(plan.deleted.steps) == set([source.step.id, fork.step.id])
        assert plan.item_ids == set([source.item.id, fork.item.id])
        refute MapSet.member?(plan.locks.chats, child_fork.chat.id)
        refute MapSet.member?(plan.locks.messages, grandchild.message.id)
        refute MapSet.member?(plan.locks.messages, sibling.message.id)
        assert plan.deleted.messages[source.message.id].status == :done
        assert plan.root_record.role == :assistant
        assert plan.barrier == {ChatMessage, source.message.id}
        assert plan.owner_id == actor.id
      end

      refute MapSet.member?(plain.locks.messages, child.message.id)
      assert MapSet.member?(kept.locks.messages, child.message.id)
      assert MapSet.member?(kept.locks.messages, parent.message.id)
      refute MapSet.member?(kept.locks.steps, child.step.id)
      assert ids(tree.deleted.chats) == set([fork.chat.id, child_fork.chat.id])

      assert ids(tree.deleted.messages) ==
               set([
                 source.message.id,
                 child.message.id,
                 grandchild.message.id,
                 fork.message.id,
                 child_fork.message.id
               ])

      refute MapSet.member?(tree.locks.messages, sibling.message.id)
    end

    test "a retry range keeps its message and uses the first removed step as barrier", %{
      actor: actor
    } do
      source = anchor!(actor)
      retained_fork = anchor!(actor, create_linked_chat!(actor, source))
      third = planner_step!(actor, source.message, 3)
      second = planner_step!(actor, source.message, 2)
      selected = %{source | step: second, item: create_item!(actor, second, type: :tool_call)}
      deleted_fork = anchor!(actor, create_linked_chat!(actor, selected))
      nested = anchor!(actor, create_linked_chat!(actor, deleted_fork))
      physical_child = anchor!(actor, source.chat, source.message.id)

      plan = prepare!({:steps, source.message.id, 2}, actor)
      assert plan.scope == {:steps, source.message.id, 2}
      assert plan.root_record.id == source.message.id
      assert plan.barrier == {ChatMessageStep, second.id}

      assert ids(plan.deleted.steps) ==
               set([second.id, third.id, deleted_fork.step.id, nested.step.id])

      refute Map.has_key?(plan.deleted.messages, source.message.id)
      assert MapSet.member?(plan.locks.messages, source.message.id)
      refute MapSet.member?(plan.locks.messages, physical_child.message.id)
      refute MapSet.member?(plan.locks.chats, retained_fork.chat.id)
      refute MapSet.member?(plan.locks.steps, source.step.id)
      refute MapSet.member?(plan.item_ids, source.item.id)

      empty = prepare!({:steps, source.message.id, 10}, actor)
      assert empty.root_record.id == source.message.id
      assert empty.barrier == nil
      assert empty.deleted == %{chats: %{}, messages: %{}, steps: %{}}
      assert empty.item_ids == MapSet.new()
      assert empty.locks.steps == MapSet.new()
      assert empty.locks.messages == set([source.message.id])
      assert empty.locks.chats == set([source.chat.id])
    end

    test "task source, handoff lifecycle and context authorities remain fenced", %{
      actor: actor
    } do
      source = anchor!(actor)
      target = anchor!(actor, create_linked_chat!(actor, source))
      lifecycle = anchor!(actor)
      context = anchor!(actor)
      unrelated = anchor!(actor)

      create_fork_task!(actor, source, target.chat, %{
        lifecycle_message_id: lifecycle.message.id,
        execution_context: %{"assistant_message_id" => context.message.id}
      })

      plan = prepare!({:chat, target.chat.id}, actor)
      assert ids(plan.deleted.chats) == set([target.chat.id])
      assert ids(plan.deleted.messages) == set([target.message.id])

      assert plan.locks.chats ==
               set([source.chat.id, target.chat.id, lifecycle.chat.id, context.chat.id])

      assert plan.locks.messages ==
               set([
                 source.message.id,
                 target.message.id,
                 lifecycle.message.id,
                 context.message.id
               ])

      assert plan.locks.steps == set([target.step.id])
      refute MapSet.member?(plan.locks.chats, unrelated.chat.id)
    end

    test "legacy references are fences, not deletions or reverse inheritance edges", %{
      actor: actor
    } do
      source = anchor!(actor)
      legacy = create_legacy_fork!(actor, source, subagent: false)
      legacy_source = anchor!(actor, legacy)
      corrupt_chat!(actor, legacy, parent_chat_id: legacy.id)
      plan = prepare!({:message, source.message.id}, actor)
      assert MapSet.member?(plan.locks.chats, legacy.id)
      assert plan.deleted.chats == %{}
      refute MapSet.member?(plan.locks.messages, legacy_source.message.id)
      assert Ash.get!(Chat, legacy.id, actor: actor).parent_message_id == source.message.id
    end

    test "preparation requires a transaction and the owner; a missing root plans nothing", %{
      actor: actor
    } do
      source = anchor!(actor)
      %{user: stranger} = user_fixture()

      assert_raise ArgumentError, @owner_only, fn ->
        LocksHelper.lock!(ChatMessage, source.message, stranger)
      end

      assert_raise ArgumentError, @owner_only, fn ->
        Locks.prepare!({:message, source.message.id}, nil)
      end

      Sandbox.unboxed_run(Repo, fn ->
        assert_raise ArgumentError, "Linked fork cleanup locks require a transaction", fn ->
          Locks.prepare!({:message, source.message.id}, actor)
        end
      end)

      {result, capture} = try_prepare({:message, -1}, actor)
      assert result == {:ok, nil}
      assert [_plan] = capture.plans
      assert [_discovery] = capture.discoveries
      assert SqlCapture.lock_queries(capture) == []
    end

    test "a readable foreign root is rejected even when the supplied owner is forged", %{
      actor: actor
    } do
      %{user: reader} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [actor, reader]})
      source = anchor!(actor)
      bot = create_bot!(actor)
      configuration = create_configuration!(actor)

      source.chat
      |> Ash.Changeset.for_update(
        :update,
        %{bot_id: bot.id, llm_configuration_id: configuration.id},
        actor: actor
      )
      |> Ash.update!(actor: actor)
      |> then(&share_chat!(actor, &1, group))

      for {resource, record, scope} <- [
            {Chat, source.chat, {:chat, source.chat.id}},
            {ChatMessage, source.message, {:message, source.message.id}},
            {ChatMessageStep, source.step, {:step, source.step.id}}
          ] do
        assert Ash.get!(resource, record.id, actor: reader).owner_id == actor.id
        {result, capture} = try_prepare(scope, reader)
        assert result == {:raised, @owner_only}
        assert SqlCapture.lock_queries(capture) == []

        assert_raise ArgumentError, @owner_only, fn ->
          Ash.transaction(resource, fn ->
            LocksHelper.lock!(resource, %{record | owner_id: reader.id}, reader)
          end)
        end
      end
    end

    test "a linked chat added after the chat fences requires a transaction retry", %{
      actor: actor
    } do
      source = anchor!(actor)
      add_fork = fn -> create_linked_chat!(actor, source) end

      {result, capture} =
        try_prepare({:step, source.step.id}, actor, after_lock: {"chats", add_fork})

      assert result == {:raised, @changed}
      assert [_plan] = capture.plans
      assert length(capture.discoveries) == 2
      assert [chat_fence] = SqlCapture.lock_queries(capture)
      assert chat_fence.sql =~ "FOR NO KEY UPDATE"
    end

    test "a new task context authority after the message fences fails before step fences", %{
      actor: actor
    } do
      source = anchor!(actor)
      handoff = anchor!(actor, source.chat)
      task = create_fork_task!(actor, source, nil, %{status: :queued, execution_context: %{}})

      add_authority = fn ->
        task
        |> Ash.Changeset.for_update(:update_state, %{}, actor: actor)
        |> Ash.Changeset.force_change_attribute(:execution_context, %{
          "message_id" => handoff.message.id
        })
        |> Ash.update!(actor: actor)
      end

      {result, capture} =
        try_prepare({:step, source.step.id}, actor, after_lock: {"chat_messages", add_authority})

      assert result == {:raised, @changed}
      assert length(capture.discoveries) == 3
      assert ["chats", "chat_messages"] = Enum.map(SqlCapture.lock_queries(capture), & &1.source)
    end

    test "steps appearing while a message fence is acquired enter the final plan", %{
      actor: actor
    } do
      source = anchor!(actor)
      add_step = fn -> planner_step!(actor, source.message, 2) end

      {result, capture} =
        try_prepare({:steps, source.message.id, 1}, actor,
          after_lock: {"chat_messages", add_step}
        )

      assert {:ok, %Plan{} = plan} = result
      assert map_size(plan.deleted.steps) == 2
      assert ids(plan.deleted.steps) == plan.locks.steps
      assert plan.barrier == {ChatMessageStep, source.step.id}
      assert length(capture.discoveries) == 3
    end
  end

  describe "cleanup operation capability" do
    setup %{actor: actor} do
      chat = create_empty_chat!(actor)
      {:ok, message} = Threads.add_message_to_end(chat, :assistant, "Operation", actor: actor)
      message = Ash.load!(message, :steps, actor: actor)
      %{chat: chat, message: message, step: hd(message.steps)}
    end

    test "expires when its scope returns, even within the same outer transaction", f do
      assert {:ok, :verified} =
               Ash.transaction(Chat, fn ->
                 operation =
                   LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, fn operation ->
                     assert Operation.record!(operation, ChatMessageStep, f.step.id, f.actor).id ==
                              f.step.id

                     operation
                   end)

                 assert_raise ArgumentError, "Cleanup operation is no longer active", fn ->
                   Operation.state!(operation, f.actor)
                 end

                 assert Ash.get!(ChatMessageStep, f.step.id, actor: f.actor)
                 :verified
               end)
    end

    test "cannot be forged, widened or used by another actor", f do
      %{user: other} = user_fixture()

      assert {:ok, :verified} =
               Ash.transaction(Chat, fn ->
                 LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, fn operation ->
                   assert_raise ArgumentError, fn -> Operation.state!(operation, other) end

                   assert_raise ArgumentError, fn ->
                     Operation.state!(%{operation | token: make_ref()}, f.actor)
                   end

                   assert_raise ArgumentError, "Record is outside the cleanup operation", fn ->
                     Operation.record!(operation, Chat, f.chat.id, f.actor)
                   end

                   assert_raise ArgumentError,
                                "Cleanup plan does not match the retry range",
                                fn ->
                                  LinkedForkCleanup.retry_steps!(
                                    operation,
                                    f.message.id,
                                    1,
                                    f.actor
                                  )
                                end

                   :verified
                 end)
               end)
    end

    test "is revoked on callback exceptions and outer rollback", f do
      assert {:ok, :verified} =
               Ash.transaction(Chat, fn ->
                 try do
                   LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, fn operation ->
                     send(self(), {:operation, operation})
                     raise "deliberate callback failure"
                   end)
                 rescue
                   RuntimeError -> :ok
                 end

                 assert_receive {:operation, operation}
                 assert_raise ArgumentError, fn -> Operation.state!(operation, f.actor) end
                 :verified
               end)

      assert {:error, _} =
               Ash.transaction(Chat, fn ->
                 LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, fn operation ->
                   send(self(), {:rolled_back_operation, operation})
                   Ash.DataLayer.rollback(Chat, :deliberate_rollback)
                 end)
               end)

      assert_receive {:rolled_back_operation, operation}
      assert_raise ArgumentError, fn -> Operation.state!(operation, f.actor) end
      assert Ash.get!(ChatMessageStep, f.step.id, actor: f.actor)
    end

    test "a captured capability cannot bypass a later destroy's preflight", f do
      assert {:ok, operation} =
               Ash.transaction(Chat, fn ->
                 LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, & &1)
               end)

      assert {:error, _} =
               f.step
               |> Ash.Changeset.for_destroy(:destroy, %{},
                 actor: f.actor,
                 context: LinkedForkCleanup.context(operation)
               )
               |> Ash.destroy(actor: f.actor)

      assert Ash.get!(ChatMessageStep, f.step.id, actor: f.actor)
      assert :ok = Ash.destroy(f.step, actor: f.actor)
    end

    for {resource, field, action} <- [
          {Chat, :chat, :destroy},
          {ChatMessage, :message, :destroy},
          {ChatMessage, :message, :destroy_with_children},
          {ChatMessageStep, :step, :destroy}
        ] do
      @resource resource
      @field field
      @action action
      test "bulk #{inspect(@resource)}.#{@action} plans a single cleanup scope", f do
        record = Map.fetch!(f, @field)

        {result, capture} =
          SqlCapture.measure(fn ->
            @resource
            |> Ash.Query.filter(id == ^record.id)
            |> Ash.bulk_destroy(@action, %{},
              actor: f.actor,
              notify?: true,
              return_errors?: true,
              return_records?: true,
              strategy: [:atomic, :stream, :atomic_batches],
              load: [:id]
            )
          end)

        assert result.status == :success
        assert result.error_count == 0
        assert [%{id: id}] = result.records
        assert id == record.id
        assert [_plan] = capture.plans
        refute @resource |> Ash.Query.filter(id == ^record.id) |> Ash.exists?(actor: f.actor)

        refute ChatMessageStep
               |> Ash.Query.filter(id == ^f.step.id)
               |> Ash.exists?(actor: f.actor)
      end
    end
  end

  describe "dependency cycles fail closed" do
    test "a cyclic legacy parent chain cannot become live fork history", %{
      actor: actor,
      source: source
    } do
      source.chat
      |> Ash.Changeset.for_update(:update, %{parent_chat_id: source.chat.id}, actor: actor)
      |> Ash.update!(actor: actor)

      assert {:error, _} = link(actor, source, %{})
    end

    # Every cleanup entry point must reject the corrupt graph before taking any
    # row fence and without deleting or reparenting anything.
    for {name, corruption, operations} <- [
          {"a linked inheritance cycle", :inheritance_cycle, [:plan_step, :destroy_step]},
          {"a self-parented source chat", :self_parent_chat, [:plan_step, :keep_children]},
          {"a physical message cycle", :message_cycle, [:plan_message_tree, :plan_chat]},
          {"a message cycle above an empty linked chat", :linked_ancestor_loop, [:plan_child]}
        ] do
      @corruption corruption
      @operations operations
      test "on #{name}", %{actor: actor, source: source} do
        f = Map.merge(%{child: nil, deleted: nil}, corrupt(@corruption, actor, source))

        for operation <- @operations do
          before = tree_state!(f.source.chat, actor)
          {result, capture} = attempt(operation, f)
          assert {:error, message} = result, inspect({operation, result})
          assert message =~ @cycle
          assert SqlCapture.lock_queries(capture) == [], inspect(operation)
          assert tree_state!(f.source.chat, actor) == before
          assert Ash.get!(ChatMessageStep, f.source.step.id, actor: actor)
          if f.child, do: assert(Ash.get!(Chat, f.child.id, actor: actor))
        end
      end
    end
  end

  defp corrupt(:inheritance_cycle, actor, source) do
    child = create_linked_chat!(actor, source)
    inner = create_tool_call_anchor!(actor, chat: child)
    corrupt_chat!(actor, source.chat, fork_link_attrs(inner, task: "cycle"))
    %{actor: actor, source: source, child: child}
  end

  defp corrupt(:self_parent_chat, actor, source) do
    deleted = create_message!(actor, source.chat, %{parent_id: source.message.id, role: :user})
    create_message!(actor, source.chat, %{parent_id: deleted.id})
    corrupt_chat!(actor, source.chat, parent_chat_id: source.chat.id)
    %{actor: actor, source: source, deleted: deleted}
  end

  defp corrupt(:message_cycle, actor, source) do
    child = anchor!(actor, source.chat, source.message.id)
    reparent_message!(actor, source.message, child.message.id)
    %{actor: actor, source: source}
  end

  defp corrupt(:linked_ancestor_loop, actor, source) do
    child = create_linked_chat!(actor, source)
    reparent_message!(actor, source.message, source.message.id)
    %{actor: actor, source: source, child: child}
  end

  defp attempt(:plan_step, f), do: plan_error({:step, f.source.step.id}, f.actor)

  defp attempt(:plan_message_tree, f),
    do: plan_error({:message_tree, f.source.message.id}, f.actor)

  defp attempt(:plan_chat, f), do: plan_error({:chat, f.source.chat.id}, f.actor)
  defp attempt(:plan_child, f), do: plan_error({:chat, f.child.id}, f.actor)

  defp attempt(:destroy_step, f) do
    {result, capture} = SqlCapture.measure(fn -> Ash.destroy(f.source.step, actor: f.actor) end)
    assert {:error, error} = result
    {{:error, Exception.message(error)}, capture}
  end

  defp attempt(:keep_children, f) do
    {result, capture} =
      SqlCapture.measure(fn ->
        Threads.delete_message_keep_children(f.source.chat.id, f.deleted.id, f.actor)
      end)

    assert {:error, error} = result
    {{:error, Exception.message(error)}, capture}
  end

  defp plan_error(scope, actor) do
    {result, capture} = try_prepare(scope, actor)
    assert {:raised, message} = result
    # Discovery stops at the cycle: one plan, one discovery pass, no fences.
    assert [_plan] = capture.plans
    assert [_discovery] = capture.discoveries
    {{:error, message}, capture}
  end

  defp link(actor, source, attrs) do
    {:ok, create_linked_chat!(actor, source, attrs)}
  rescue
    error in [Ash.Error.Invalid, Ash.Error.Forbidden] -> {:error, error}
  end

  defp prepare!(scope, actor) do
    assert {{:ok, plan}, _capture} = try_prepare(scope, actor)
    assert is_nil(plan) or match?(%Plan{}, plan)
    plan
  end

  defp try_prepare(scope, actor, opts \\ []) do
    SqlCapture.measure(
      fn ->
        try do
          Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
            Locks.prepare!(scope, actor)
          end)
        rescue
          error in ArgumentError -> {:raised, Exception.message(error)}
        end
      end,
      opts
    )
  end

  defp anchor!(actor, chat \\ nil, parent_id \\ nil) do
    create_tool_call_anchor!(actor,
      chat: chat || create_empty_chat!(actor),
      message: %{parent_id: parent_id},
      step: planner_step_attrs(1)
    )
  end

  defp planner_step!(actor, message, sequence),
    do: create_step!(actor, message, planner_step_attrs(sequence))

  # Raw payloads let whitebox tests prove the planner never selects them.
  defp planner_step_attrs(sequence) do
    %{
      sequence: sequence,
      response_final: true,
      raw_request: %{"not_for_planner" => true},
      raw_response: %{"not_for_planner" => true}
    }
  end

  defp fork_anchor!(actor, chat, parent_id) do
    create_tool_call_anchor!(actor,
      chat: chat,
      message: %{parent_id: parent_id},
      step: %{response_final: true},
      content: %{kind: :opaque, content_json: fork_call_payload()}
    )
  end

  defp tree_state!(chat, actor) do
    messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(actor: actor)

    {Ash.get!(Chat, chat.id, actor: actor).last_message_id,
     Enum.map(messages, &{&1.id, &1.parent_id})}
  end

  defp set(ids), do: MapSet.new(ids)
  defp ids(records), do: records |> Map.keys() |> set()
end
