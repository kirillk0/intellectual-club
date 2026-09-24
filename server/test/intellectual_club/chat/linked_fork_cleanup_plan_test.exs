defmodule IntellectualClub.Chat.LinkedForkCleanupPlanTest do
  use IntellectualClub.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ForkHistoryCorruptFixture
  alias IntellectualClub.Chat.LinkedForkCleanup.Plan
  alias IntellectualClub.Chat.LinkedForkCleanupLocks, as: Locks
  alias IntellectualClub.Chat.LinkedForkCleanupLocksHelper, as: LocksHelper

  @plan_event [:intellectual_club, :linked_fork_cleanup, :plan]
  @discover_event [:intellectual_club, :linked_fork_cleanup, :discover]
  @query_event [:intellectual_club, :repo, :query]

  setup do
    %{user: actor} = user_fixture()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [@plan_event, @discover_event, @query_event],
        &__MODULE__.record_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{actor: actor}
  end

  test "message, tree and reparent scopes distinguish deletion from fences", %{actor: actor} do
    parent = anchor!(actor)
    source = anchor!(actor, parent.chat, parent.message.id)
    child = anchor!(actor, parent.chat, source.message.id)
    grandchild = anchor!(actor, parent.chat, child.message.id)
    sibling = anchor!(actor, parent.chat, parent.message.id)
    fork = anchor!(actor, linked_chat!(source, actor))
    child_fork = anchor!(actor, linked_chat!(child, actor))

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

  test "retry range retains its message and uses the first removed sequence as barrier", %{
    actor: actor
  } do
    source = anchor!(actor)
    retained_fork = anchor!(actor, linked_chat!(source, actor))
    third = step!(source.message, 3, actor)
    second = step!(source.message, 2, actor)
    selected_source = %{source | step: second, item: item!(second, actor)}
    deleted_fork = anchor!(actor, linked_chat!(selected_source, actor))
    nested = anchor!(actor, linked_chat!(deleted_fork, actor))
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

  test "task source, handoff lifecycle and context authorities outside deletion remain fenced", %{
    actor: actor
  } do
    source = anchor!(actor)
    target = anchor!(actor, linked_chat!(source, actor))
    lifecycle = anchor!(actor)
    context = anchor!(actor)
    unrelated = anchor!(actor)

    BackgroundTask
    |> Ash.Changeset.for_create(
      :create,
      %{
        kind: "fork",
        adapter: "cleanup_plan_test",
        function_name: "fork",
        status: :completed,
        source_chat_id: source.chat.id,
        source_message_id: source.message.id,
        lifecycle_message_id: lifecycle.message.id,
        source_step_id: source.step.id,
        source_tool_call_item_id: source.item.id,
        target_chat_id: target.chat.id,
        execution_context: %{"assistant_message_id" => context.message.id}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    plan = prepare!({:chat, target.chat.id}, actor)
    assert ids(plan.deleted.chats) == set([target.chat.id])
    assert ids(plan.deleted.messages) == set([target.message.id])

    assert plan.locks.chats ==
             set([source.chat.id, target.chat.id, lifecycle.chat.id, context.chat.id])

    assert plan.locks.messages ==
             set([source.message.id, target.message.id, lifecycle.message.id, context.message.id])

    assert plan.locks.steps == set([target.step.id])
    refute MapSet.member?(plan.locks.chats, unrelated.chat.id)
  end

  test "legacy references are fences, not deletions or reverse inheritance edges", %{actor: actor} do
    source = anchor!(actor)

    legacy =
      Chat
      |> Ash.Changeset.for_create(
        :create_empty,
        %{
          parent_chat_id: source.chat.id,
          parent_message_id: source.message.id,
          parent_relation_kind: :fork
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    legacy_source = anchor!(actor, legacy)
    corrupt_chat!(legacy, %{parent_chat_id: legacy.id}, actor)
    plan = prepare!({:message, source.message.id}, actor)
    assert MapSet.member?(plan.locks.chats, legacy.id)
    assert plan.deleted.chats == %{}
    refute MapSet.member?(plan.locks.messages, legacy_source.message.id)
    assert Ash.get!(Chat, legacy.id, actor: actor).parent_message_id == source.message.id
  end

  test "logical inheritance cycles fail before any row fence", %{actor: actor} do
    source = anchor!(actor)
    child = anchor!(actor, linked_chat!(source, actor))

    corrupt_chat!(
      source.chat,
      %{
        parent_chat_id: child.chat.id,
        parent_message_id: child.message.id,
        fork_source_step_id: child.step.id,
        fork_task: "corrupt cycle"
      },
      actor
    )

    reset_events()

    assert_raise ArgumentError, "Cycle in linked fork cleanup dependencies", fn ->
      prepare!({:step, source.step.id}, actor)
    end

    assert fence_queries() == []
    assert length(events(@plan_event)) == 1
    assert length(events(@discover_event)) == 1
  end

  test "tree and chat scopes reject physical message cycles before fencing", %{actor: actor} do
    source = anchor!(actor)
    child = anchor!(actor, source.chat, source.message.id)

    source.message
    |> Ash.Changeset.for_update(:set_generation_state, %{}, actor: actor)
    |> Ash.Changeset.force_change_attribute(:parent_id, child.message.id)
    |> Ash.update!(actor: actor)

    for scope <- [{:message_tree, source.message.id}, {:chat, source.chat.id}] do
      reset_events()

      assert_raise ArgumentError, "Cycle in linked fork cleanup dependencies", fn ->
        prepare!(scope, actor)
      end

      assert fence_queries() == []
    end
  end

  test "an empty linked chat still checks physical ancestor message edges", %{actor: actor} do
    source = anchor!(actor)
    child = linked_chat!(source, actor)

    source.message
    |> Ash.Changeset.for_update(:set_generation_state, %{}, actor: actor)
    |> Ash.Changeset.force_change_attribute(:parent_id, source.message.id)
    |> Ash.update!(actor: actor)

    reset_events()

    assert_raise ArgumentError, "Cycle in linked fork cleanup dependencies", fn ->
      prepare!({:chat, child.id}, actor)
    end

    assert fence_queries() == []
  end

  test "preparation is transaction-only and the compatibility wrapper rejects foreign records", %{
    actor: actor
  } do
    source = anchor!(actor)
    %{user: stranger} = user_fixture()

    assert_raise ArgumentError, "Only the owner can lock linked fork cleanup dependencies", fn ->
      LocksHelper.lock!(ChatMessage, source.message, stranger)
    end

    assert_raise ArgumentError, "Only the owner can lock linked fork cleanup dependencies", fn ->
      Locks.prepare!({:message, source.message.id}, nil)
    end

    Sandbox.unboxed_run(Repo, fn ->
      assert_raise ArgumentError, "Linked fork cleanup locks require a transaction", fn ->
        Locks.prepare!({:message, source.message.id}, actor)
      end
    end)

    reset_events()
    assert prepare!({:message, -1}, actor) == nil
    assert length(events(@plan_event)) == 1
    assert length(events(@discover_event)) == 1
    assert fence_queries() == []
  end

  test "a readable foreign root is rejected even when the supplied owner is forged", %{
    actor: actor
  } do
    %{user: reader} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [actor, reader]})
    source = anchor!(actor)

    provider =
      IntellectualClub.Llm.LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Planner fixture",
          type: :responses,
          base_url: "https://example.invalid/v1",
          api_key: "fixture"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      IntellectualClub.Llm.LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{provider_id: provider.id, model_name: "fixture", parameters: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    bot =
      IntellectualClub.Bots.Bot
      |> Ash.Changeset.for_create(:create, %{name: "Planner fixture", first_messages: []},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    source.chat
    |> Ash.Changeset.for_update(
      :update,
      %{bot_id: bot.id, llm_configuration_id: configuration.id},
      actor: actor
    )
    |> Ash.update!(actor: actor)

    IntellectualClub.Chat.ChatShare
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_id: source.chat.id,
        user_group_id: group.id,
        bot_id: bot.id,
        llm_configuration_id: configuration.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    for {resource, record, scope} <- [
          {Chat, source.chat, {:chat, source.chat.id}},
          {ChatMessage, source.message, {:message, source.message.id}},
          {ChatMessageStep, source.step, {:step, source.step.id}}
        ] do
      assert Ash.get!(resource, record.id, actor: reader).owner_id == actor.id
      reset_events()

      assert_raise ArgumentError,
                   "Only the owner can lock linked fork cleanup dependencies",
                   fn ->
                     prepare!(scope, reader)
                   end

      assert fence_queries() == []

      assert_raise ArgumentError,
                   "Only the owner can lock linked fork cleanup dependencies",
                   fn ->
                     Ash.transaction(resource, fn ->
                       LocksHelper.lock!(resource, %{record | owner_id: reader.id}, reader)
                     end)
                   end
    end
  end

  test "one plan emits three discoveries, orders fences and never selects raw payloads", %{
    actor: actor
  } do
    source = anchor!(actor)
    child = anchor!(actor, linked_chat!(source, actor))
    reset_events()
    plan = prepare!({:chat, source.chat.id}, actor)
    assert plan.barrier == {Chat, source.chat.id}
    assert ids(plan.deleted.chats) == set([source.chat.id, child.chat.id])
    assert [{%{count: 1}, %{scope: {:chat, id}}}] = events(@plan_event)
    assert id == source.chat.id
    assert length(events(@discover_event)) == 3

    assert [chats, messages, steps, root] = fence_queries()
    assert chats =~ ~s(FROM "chats")
    assert chats =~ "FOR NO KEY UPDATE"
    assert messages =~ ~s(FROM "chat_messages")
    assert messages =~ "FOR UPDATE"
    assert steps =~ ~s(FROM "chat_message_steps")
    assert steps =~ "FOR UPDATE"
    assert root =~ ~s(FROM "chats")
    assert root =~ "FOR UPDATE"
    refute Enum.any?(queries(), &String.contains?(&1, [~s("raw_request"), ~s("raw_response")]))

    reset_events()
    step_plan = prepare!({:step, source.step.id}, actor)
    assert step_plan.root_record.id == source.step.id
    refute Ash.Resource.selected?(step_plan.root_record, :raw_request)
    refute Ash.Resource.selected?(step_plan.root_record, :raw_response)
    assert Enum.count(fence_queries(), &(&1 =~ ~s(FROM "chats"))) == 1
  end

  test "local step discovery stays bounded without reading or locking its physical siblings", %{
    actor: actor
  } do
    source = anchor!(actor)
    reset_events()
    prepare!({:step, source.step.id}, actor)
    small = length(queries())

    tail =
      Enum.reduce(1..15, source, fn _, parent ->
        anchor!(actor, source.chat, parent.message.id)
      end)

    reset_events()
    plan = prepare!({:step, tail.step.id}, actor)
    assert length(queries()) == small
    assert small <= 35
    assert plan.locks.messages == set([tail.message.id])
    assert plan.locks.steps == set([tail.step.id])

    assert Enum.count(queries(), &(&1 =~ ~s(FROM "chat_messages") and not (&1 =~ "FOR UPDATE"))) ==
             3
  end

  test "tree discovery loads local messages once per pass rather than once per depth", %{
    actor: actor
  } do
    source = anchor!(actor)

    _tail =
      Enum.reduce(1..12, source, fn _, parent ->
        anchor!(actor, source.chat, parent.message.id)
      end)

    reset_events()
    plan = prepare!({:message_tree, source.message.id}, actor)
    assert map_size(plan.deleted.messages) == 13
    assert map_size(plan.deleted.steps) == 13
    assert length(queries()) <= 35

    local_loads =
      Enum.filter(queries(), fn query ->
        query =~ ~s(FROM "chat_messages") and
          not String.contains?(query, ["FOR UPDATE", ~s("role")])
      end)

    assert length(local_loads) == 3
  end

  test "a linked chat added after chat fences requires a transaction retry", %{actor: actor} do
    source = anchor!(actor)
    reset_events()
    after_fence("chats", fn -> linked_chat!(source, actor) end)

    assert_raise ArgumentError,
                 "Linked fork cleanup dependencies changed; retry the transaction",
                 fn ->
                   prepare!({:step, source.step.id}, actor)
                 end

    assert length(events(@plan_event)) == 1
    assert length(events(@discover_event)) == 2
    assert [chat_fence] = fence_queries()
    assert chat_fence =~ "FOR NO KEY UPDATE"
  end

  test "a new task context authority after message fences fails before step fences", %{
    actor: actor
  } do
    source = anchor!(actor)
    handoff = anchor!(actor, source.chat)

    task =
      BackgroundTask
      |> Ash.Changeset.for_create(
        :create,
        %{
          kind: "fork",
          adapter: "cleanup_plan_test",
          function_name: "fork",
          source_chat_id: source.chat.id,
          source_message_id: source.message.id,
          source_step_id: source.step.id,
          execution_context: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    reset_events()

    after_fence("chat_messages", fn ->
      task
      |> Ash.Changeset.for_update(:update_state, %{}, actor: actor)
      |> Ash.Changeset.force_change_attribute(:execution_context, %{
        "message_id" => handoff.message.id
      })
      |> Ash.update!(actor: actor)
    end)

    assert_raise ArgumentError,
                 "Linked fork cleanup dependencies changed; retry the transaction",
                 fn ->
                   prepare!({:step, source.step.id}, actor)
                 end

    assert length(events(@discover_event)) == 3
    assert [chats, messages] = fence_queries()
    assert chats =~ ~s(FROM "chats")
    assert messages =~ ~s(FROM "chat_messages")
  end

  test "steps appearing while a message fence is acquired enter the final plan", %{actor: actor} do
    source = anchor!(actor)
    reset_events()
    after_fence("chat_messages", fn -> step!(source.message, 2, actor) end)
    plan = prepare!({:steps, source.message.id, 1}, actor)
    assert map_size(plan.deleted.steps) == 2
    assert ids(plan.deleted.steps) == plan.locks.steps
    assert plan.barrier == {ChatMessageStep, source.step.id}
    assert length(events(@discover_event)) == 3
  end

  defp after_fence(table, fun), do: Process.put({__MODULE__, :after_fence}, {table, fun})

  @doc false
  def record_event(event, measurements, metadata, owner) do
    if self() == owner do
      Process.put({__MODULE__, :events}, [
        {event, measurements, metadata} | Process.get({__MODULE__, :events}, [])
      ])

      case Process.get({__MODULE__, :after_fence}) do
        {table, fun} when event == @query_event ->
          if String.contains?(metadata.query, ~s(FROM "#{table}")) and
               String.contains?(metadata.query, ["FOR UPDATE", "FOR NO KEY UPDATE"]) do
            Process.delete({__MODULE__, :after_fence})
            fun.()
          end

        _ ->
          :ok
      end
    end
  end

  defp reset_events, do: Process.put({__MODULE__, :events}, [])

  defp events(event) do
    for {^event, measurements, metadata} <- Enum.reverse(Process.get({__MODULE__, :events}, [])),
        do: {measurements, metadata}
  end

  defp queries,
    do: Enum.map(events(@query_event), fn {_measurements, metadata} -> metadata.query end)

  defp fence_queries,
    do: Enum.filter(queries(), &String.contains?(&1, ["FOR UPDATE", "FOR NO KEY UPDATE"]))

  defp set(ids), do: MapSet.new(ids)
  defp ids(records), do: records |> Map.keys() |> set()

  defp prepare!(scope, actor) do
    assert {:ok, plan} =
             Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
               Locks.prepare!(scope, actor)
             end)

    assert is_nil(plan) or match?(%Plan{}, plan)
    plan
  end

  defp anchor!(actor, chat \\ nil, parent_id \\ nil) do
    chat =
      chat ||
        Chat
        |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
        |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{chat_id: chat.id, parent_id: parent_id, role: :assistant, status: :done},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step = step!(message, 1, actor)
    %{chat: chat, message: message, step: step, item: item!(step, actor)}
  end

  defp step!(message, sequence, actor) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_id: message.id,
        sequence: sequence,
        response_final: true,
        raw_request: %{"not_for_planner" => true},
        raw_response: %{"not_for_planner" => true}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp item!(step, actor) do
    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_step_id: step.id, sequence: 1, type: :tool_call},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp linked_chat!(source, actor) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        parent_chat_id: source.chat.id,
        parent_message_id: source.message.id,
        parent_tool_call_item_id: source.item.id,
        parent_relation_kind: :fork,
        subagent: true
      },
      actor: actor
    )
    |> Ash.Changeset.force_change_attributes(%{
      fork_source_step_id: source.step.id,
      fork_task: "Planner fixture"
    })
    |> Ash.create!(actor: actor)
  end

  defp corrupt_chat!(chat, attrs, actor) do
    ForkHistoryCorruptFixture
    |> Ash.get!(chat.id, actor: actor)
    |> Ash.Changeset.for_update(:corrupt_anchor, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end
end
