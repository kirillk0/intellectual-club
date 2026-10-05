defmodule IntellectualClub.Chat.LinkedForkCleanupPerformanceTest do
  @moduledoc """
  Whitebox cost of linked fork cleanup: one plan per operation, a bounded
  number of discovery passes and queries independent of retained history, row
  locks limited to the mutated rows, and no raw payload reads.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.LinkedForkCleanup
  alias IntellectualClub.Chat.LinkedForkCleanupLocks, as: Locks
  alias IntellectualClub.SqlCapture
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence

  @moduletag :whitebox

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor}
  end

  describe "cleanup plan" do
    test "one plan emits three discoveries, orders fences and never selects raw payloads", %{
      actor: actor
    } do
      [source] = history!(actor, 1)
      [child] = history!(actor, 1, create_linked_chat!(actor, source))
      {plan, capture} = prepare!({:chat, source.chat.id}, actor)
      assert plan.barrier == {Chat, source.chat.id}
      assert ids(plan.deleted.chats) == MapSet.new([source.chat.id, child.chat.id])
      assert [{%{count: 1}, %{scope: {:chat, id}}}] = capture.plans
      assert id == source.chat.id
      assert length(capture.discoveries) == 3

      assert [chats, messages, steps, root] = Enum.map(SqlCapture.lock_queries(capture), & &1.sql)
      assert chats =~ ~s(FROM "chats")
      assert chats =~ "FOR NO KEY UPDATE"
      assert messages =~ ~s(FROM "chat_messages")
      assert messages =~ "FOR UPDATE"
      assert steps =~ ~s(FROM "chat_message_steps")
      assert steps =~ "FOR UPDATE"
      assert root =~ ~s(FROM "chats")
      assert root =~ "FOR UPDATE"

      refute Enum.any?(
               capture.queries,
               &String.contains?(&1.sql, [~s("raw_request"), ~s("raw_response")])
             )

      {step_plan, capture} = prepare!({:step, source.step.id}, actor)
      assert step_plan.root_record.id == source.step.id
      refute Ash.Resource.selected?(step_plan.root_record, :raw_request)
      refute Ash.Resource.selected?(step_plan.root_record, :raw_response)
      assert Enum.count(SqlCapture.lock_queries(capture), &(&1.source == "chats")) == 1
    end

    test "local step discovery neither reads nor locks its physical ancestors", %{actor: actor} do
      [source] = history!(actor, 1)
      {_plan, small} = prepare!({:step, source.step.id}, actor)
      tail = List.last(history!(actor, 15, source.chat, source.message.id))
      {plan, large} = prepare!({:step, tail.step.id}, actor)
      assert length(large.queries) == length(small.queries)
      assert length(small.queries) <= 35
      assert plan.locks.messages == MapSet.new([tail.message.id])
      assert plan.locks.steps == MapSet.new([tail.step.id])
      assert Enum.count(large.queries, &(&1.source == "chat_messages" and not &1.lock?)) == 3
    end

    test "tree discovery loads local messages once per pass rather than once per depth", %{
      actor: actor
    } do
      [source | _tail] = history!(actor, 13)
      {plan, capture} = prepare!({:message_tree, source.message.id}, actor)
      assert map_size(plan.deleted.messages) == 13
      assert map_size(plan.deleted.steps) == 13
      assert length(capture.queries) <= 35

      local_loads =
        Enum.filter(capture.queries, fn query ->
          query.source == "chat_messages" and not query.lock? and
            not String.contains?(query.sql, ~s("role"))
        end)

      assert length(local_loads) == 3
    end
  end

  describe "cleanup operations" do
    test "chat cascades reuse one plan and avoid per-message rediscovery", %{actor: actor} do
      [small, large] =
        for count <- [3, 30] do
          anchors = history!(actor, count)
          chat = hd(anchors).chat
          {result, stats} = measure(fn -> Ash.destroy(chat, actor: actor) end)
          assert result == :ok
          assert_one_plan(stats)
          assert_missing!(Chat, chat.id, actor)
          assert_missing!(ChatMessageStep, List.last(anchors).step.id, actor)
          stats
        end

      # Ash item/message cascades stay linear; repeated cleanup planning must not.
      assert large.queries <= small.queries + 50 * (30 - 3), inspect([small, large])
    end

    test "keep-children deletion near the start fences neither retained history nor depth", %{
      actor: actor
    } do
      [small, large] =
        for count <- [5, 30] do
          [parent, deleted, child | rest] = anchors = history!(actor, count)

          {result, stats} =
            measure(fn ->
              Threads.delete_message_keep_children(parent.chat, deleted.message.id, actor)
            end)

          assert {:ok, _branch} = result
          assert_one_plan(stats)
          assert_missing!(ChatMessage, deleted.message.id, actor)
          assert MapSet.member?(stats.locked_ids["chat_messages"], deleted.message.id)
          assert MapSet.member?(stats.locked_ids["chat_message_steps"], deleted.step.id)

          assert Ash.get!(ChatMessage, child.message.id, actor: actor).parent_id ==
                   parent.message.id

          assert Ash.get!(ChatMessage, List.last(anchors).message.id, actor: actor)
          # The direct child is updated by reparenting. Deep descendants are not mutation targets.
          assert_no_locks(stats, "chat_messages", Enum.map(rest, & &1.message.id))
          assert_no_locks(stats, "chat_message_steps", Enum.map([child | rest], & &1.step.id))
          stats
        end

      assert large.queries <= small.queries + 10, inspect([small, large])
    end

    test "one-step retry cost is independent of retained descendants and siblings", %{
      actor: actor
    } do
      [small, large] =
        for retained_count <- [3, 30] do
          fixture = retry_fixture!(actor, 1, retained_count)
          {_replacement, stats} = claim_retry!(fixture, actor)
          stats
        end

      # A modest fixed margin, never a budget proportional to retained rows.
      assert large.queries <= small.queries + 30, inspect([small, large])
      assert large.lock_queries <= small.lock_queries + 3, inspect([small, large])
    end

    test "retrying many steps still creates exactly one operation plan", %{actor: actor} do
      [one, many] =
        for count <- [1, 12] do
          {_replacement, stats} = claim_retry!(retry_fixture!(actor, count, 3), actor)
          stats
        end

      assert many.queries <= one.queries + 25 * (12 - 1), inspect([one, many])
    end

    test "a retry claim and an existing lease pass one plan through replacement", %{
      actor: actor
    } do
      fixture = retry_fixture!(actor, 12, 3)
      message_id = fixture.source.message.id
      assert {:ok, reservation} = Lease.reserve(message_id)

      with_scope = fn callback ->
        LinkedForkCleanup.with_scope({:steps, message_id, 2}, actor, callback)
      end

      replace = fn operation, lease ->
        Persistence.replace_steps_for_retry!(message_id, 2, %{}, [], operation, lease: lease)
      end

      try do
        {claim, stats} =
          measure(fn ->
            Lease.claim_and_run_with_chat(
              reservation,
              fixture.source.chat.id,
              [:done],
              replace,
              with_lock_scope: with_scope
            )
          end)

        assert {:ok, {fenced, replacement_id}} = claim
        assert is_integer(replacement_id)
        assert_one_plan(stats)
        assert_retry_scope(fixture, stats, actor)

        {retry, stats} =
          measure(fn ->
            Lease.with_fence(fenced, &replace.(&1, fenced), with_lock_scope: with_scope)
          end)

        assert {:ok, next_replacement} = retry
        assert is_integer(next_replacement)
        assert_one_plan(stats)
        assert_missing!(ChatMessageStep, replacement_id, actor)
      after
        Lease.release(reservation)
      end
    end

    test "linked and nested chat destruction share their root plan", %{actor: actor} do
      for depth <- [1, 2] do
        [source] = history!(actor, 1)

        last =
          Enum.reduce(1..depth, source, fn _, anchor ->
            hd(history!(actor, 1, create_linked_chat!(actor, anchor)))
          end)

        {result, stats} = measure(fn -> Ash.destroy(source.chat, actor: actor) end)
        assert result == :ok
        assert_one_plan(stats)
        assert_missing!(Chat, last.chat.id, actor)
        assert_missing!(ChatMessageStep, last.step.id, actor)
      end
    end

    test "a single message destroy without children plans once", %{actor: actor} do
      [anchor] = history!(actor, 1)
      {result, stats} = measure(fn -> Ash.destroy(anchor.message, actor: actor) end)
      assert result == :ok
      assert_one_plan(stats)
      assert_missing!(ChatMessageStep, anchor.step.id, actor)
    end
  end

  defp measure(operation) do
    {result, capture} = SqlCapture.measure(operation)

    stats = %{
      queries: length(capture.queries),
      lock_queries: length(SqlCapture.lock_queries(capture)),
      locked_ids: SqlCapture.locked_ids(capture),
      plans: length(capture.plans),
      discoveries: length(capture.discoveries)
    }

    {result, stats}
  end

  defp prepare!(scope, actor) do
    {result, capture} =
      SqlCapture.measure(fn ->
        Ash.transaction([Chat, ChatMessage, ChatMessageStep], fn ->
          Locks.prepare!(scope, actor)
        end)
      end)

    assert {:ok, plan} = result
    {plan, capture}
  end

  defp claim_retry!(fixture, actor) do
    message_id = fixture.source.message.id
    assert {:ok, reservation} = Lease.reserve(message_id)

    with_scope = fn callback ->
      LinkedForkCleanup.with_scope({:steps, message_id, 2}, actor, callback)
    end

    {result, stats} =
      measure(fn ->
        Lease.claim_and_run_with_chat(
          reservation,
          fixture.source.chat.id,
          [:done],
          fn operation, fenced ->
            Persistence.replace_steps_for_retry!(message_id, 2, %{}, [], operation, lease: fenced)
          end,
          with_lock_scope: with_scope
        )
      end)

    assert {:ok, {fenced, replacement}} = result
    assert :ok = Lease.release(fenced)
    assert is_integer(replacement)
    assert_one_plan(stats)
    assert_retry_scope(fixture, stats, actor)
    {replacement, stats}
  end

  defp assert_one_plan(stats) do
    assert stats.plans == 1, inspect(stats)
    assert stats.discoveries in 1..3, inspect(stats)
    assert stats.queries > 0
    assert stats.lock_queries > 0
  end

  defp assert_retry_scope(fixture, stats, actor) do
    Enum.each(fixture.removed_steps, &assert_missing!(ChatMessageStep, &1.id, actor))
    assert MapSet.member?(stats.locked_ids["chat_messages"], fixture.source.message.id)

    for step <- fixture.removed_steps do
      assert MapSet.member?(stats.locked_ids["chat_message_steps"], step.id)
    end

    assert Ash.get!(ChatMessageStep, fixture.source.step.id, actor: actor)
    assert Ash.get!(Chat, fixture.retained_fork.id, actor: actor)
    assert Ash.get!(Chat, fixture.independent_fork.id, actor: actor)
    retained = fixture.descendants ++ fixture.siblings ++ fixture.fork_history
    retained = [fixture.independent_source | retained]
    assert_no_locks(stats, "chat_messages", Enum.map(retained, & &1.message.id))

    assert_no_locks(stats, "chat_message_steps", [
      fixture.source.step.id | Enum.map(retained, & &1.step.id)
    ])

    assert_no_locks(stats, "chats", [
      fixture.retained_fork.id,
      fixture.independent_fork.id,
      fixture.independent_source.chat.id
    ])

    assert Ash.get!(ChatMessage, List.last(fixture.descendants).message.id, actor: actor)
    assert Ash.get!(ChatMessage, List.last(fixture.siblings).message.id, actor: actor)
  end

  defp assert_no_locks(stats, table, ids) do
    unexpected =
      MapSet.intersection(Map.get(stats.locked_ids, table, MapSet.new()), MapSet.new(ids))

    assert MapSet.size(unexpected) == 0, "Unexpected #{table} row locks: #{inspect(unexpected)}"
  end

  # A chain of `count` tool-call anchors (each the parent of the next).
  defp history!(actor, count, chat \\ nil, parent_id \\ nil) do
    chat = chat || create_empty_chat!(actor)

    {anchors, _parent_id} =
      Enum.map_reduce(1..count, parent_id, fn _, parent_id ->
        anchor =
          create_tool_call_anchor!(actor,
            chat: chat,
            message: %{parent_id: parent_id},
            step: %{
              response_final: true,
              raw_request: %{"not_for_planner" => true},
              raw_response: %{"not_for_planner" => true}
            }
          )

        {anchor, anchor.message.id}
      end)

    anchors
  end

  defp retry_fixture!(actor, removed_count, retained_count) do
    [source] = history!(actor, 1)

    removed_steps =
      Enum.map(2..(removed_count + 1), &create_step!(actor, source.message, sequence: &1))

    retained_fork = create_linked_chat!(actor, source)
    [independent_source] = history!(actor, 1)

    %{
      source: source,
      removed_steps: removed_steps,
      descendants: history!(actor, retained_count, source.chat, source.message.id),
      siblings: history!(actor, retained_count, source.chat),
      retained_fork: retained_fork,
      fork_history: history!(actor, retained_count, retained_fork),
      independent_fork: create_linked_chat!(actor, independent_source),
      independent_source: independent_source
    }
  end

  defp ids(records), do: records |> Map.keys() |> MapSet.new()
end
