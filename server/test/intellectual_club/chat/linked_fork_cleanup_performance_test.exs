defmodule IntellectualClub.Chat.LinkedForkCleanupPerformanceTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Chat.LinkedForkCleanup
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence

  @moduletag :cleanup_performance
  @moduletag timeout: 180_000
  @plan_event [:intellectual_club, :linked_fork_cleanup, :plan]
  @discover_event [:intellectual_club, :linked_fork_cleanup, :discover]
  @sql_event [:intellectual_club, :repo, :query]

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor}
  end

  test "chat cascades reuse one plan and avoid per-message cleanup rediscovery", %{actor: actor} do
    measurements =
      for count <- [10, 100] do
        {chat, messages} = history!(actor, count)

        {result, stats} =
          measure("chat_delete_n#{count}", fn -> Ash.destroy(chat, actor: actor) end)

        assert result == :ok
        assert_one_plan(stats)
        assert_missing(Chat, chat.id, actor)
        assert_missing(ChatMessageStep, List.last(messages).step.id, actor)
        stats
      end

    [small, large] = measurements
    # Normal Ash item/message cascades remain linear; repeated cleanup planning must not.
    assert large.queries <= small.queries + 50 * (100 - 10), inspect(measurements)
  end

  test "keep-children deletion near the start does not fence the retained history", %{
    actor: actor
  } do
    {chat, messages} = history!(actor, 100)
    [parent, deleted, child | _rest] = messages

    {result, stats} =
      measure("keep_children_n100", fn ->
        Threads.delete_message_keep_children(chat, deleted.message.id, actor)
      end)

    assert {:ok, _branch} = result
    assert_one_plan(stats)
    assert stats.queries < 300, inspect(stats)
    assert_missing(ChatMessage, deleted.message.id, actor)
    assert deleted.message.id in Map.fetch!(stats.locked_ids, "chat_messages")
    assert deleted.step.id in Map.fetch!(stats.locked_ids, "chat_message_steps")
    assert Ash.get!(ChatMessage, child.message.id, actor: actor).parent_id == parent.message.id
    assert Ash.get!(ChatMessage, List.last(messages).message.id, actor: actor)
    # The direct child is updated by reparenting. Deep descendants are not mutation targets.
    assert_no_locks(stats, "chat_messages", Enum.map(Enum.drop(messages, 3), & &1.message.id))
    assert_no_locks(stats, "chat_message_steps", Enum.map(Enum.drop(messages, 2), & &1.step.id))
  end

  test "one-step retry cost is independent of preserved descendant and sibling history", %{
    actor: actor
  } do
    measurements =
      for retained_count <- [10, 100] do
        fixture = retry_fixture!(actor, 1, retained_count)

        {replacement, stats} =
          measure("retry_one_retained_n#{retained_count}", fn ->
            Persistence.replace_steps_for_retry!(fixture.source.message.id, 2, %{})
          end)

        assert is_integer(replacement)
        assert_one_plan(stats)
        assert_retry_scope(fixture, stats, actor)
        stats
      end

    [small, large] = measurements
    # Allow a modest fixed margin, never a budget proportional to retained rows.
    assert large.queries <= small.queries + 30, inspect(measurements)
    assert large.lock_queries <= small.lock_queries + 3, inspect(measurements)
  end

  test "retrying many steps still creates exactly one operation plan", %{actor: actor} do
    measurements =
      for count <- [1, 12] do
        fixture = retry_fixture!(actor, count, 10)
        label = if count == 1, do: "retry_one_retained_n10", else: "retry_twelve_retained_n10"

        {replacement, stats} =
          measure(label, fn ->
            Persistence.replace_steps_for_retry!(fixture.source.message.id, 2, %{})
          end)

        assert is_integer(replacement)
        assert_one_plan(stats)
        assert_retry_scope(fixture, stats, actor)
        stats
      end

    [one, many] = measurements
    assert many.queries <= one.queries + 25 * (12 - 1), inspect(measurements)
  end

  @tag :optimized_retry_api
  test "retry claim and an existing lease pass one plan through replacement", %{actor: actor} do
    fixture = retry_fixture!(actor, 12, 10)
    message_id = fixture.source.message.id
    assert {:ok, reservation} = Lease.reserve(message_id)

    with_scope = fn callback ->
      LinkedForkCleanup.with_scope({:steps, message_id, 2}, actor, callback)
    end

    replace = fn operation ->
      Persistence.replace_steps_for_retry!(message_id, 2, %{}, [], operation)
    end

    try do
      {claim, stats} =
        measure("retry_claim_twelve", fn ->
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
        measure("retry_existing_fence", fn ->
          Lease.with_fence(fenced, replace, with_lock_scope: with_scope)
        end)

      assert {:ok, next_replacement} = retry
      assert is_integer(next_replacement)
      assert_one_plan(stats)
      assert_missing(ChatMessageStep, replacement_id, actor)
    after
      Lease.release(reservation)
    end
  end

  test "linked and nested chat destruction share their root plan", %{actor: actor} do
    for depth <- [1, 2] do
      {chat, anchors} = history!(actor, 1)
      source = hd(anchors)

      {last_chat, last_anchor} =
        Enum.reduce(1..depth, {chat, source}, fn _, {_chat, anchor} ->
          child = linked_chat!(anchor, actor)
          {child, [nested_anchor]} = history!(actor, 1, child)
          {child, nested_anchor}
        end)

      {result, stats} =
        measure("linked_chat_depth#{depth}", fn -> Ash.destroy(chat, actor: actor) end)

      assert result == :ok
      assert_one_plan(stats)
      assert_missing(Chat, last_chat.id, actor)
      assert_missing(ChatMessageStep, last_anchor.step.id, actor)
    end
  end

  test "public single-message destroy without children plans once", %{actor: actor} do
    {_chat, [anchor]} = history!(actor, 1)

    {result, stats} =
      measure("single_message", fn -> Ash.destroy(anchor.message, actor: actor) end)

    assert result == :ok
    assert_one_plan(stats)
    assert_missing(ChatMessageStep, anchor.step.id, actor)
  end

  defp assert_one_plan(stats) do
    assert stats.plans == 1, inspect(stats)
    assert stats.discoveries in 1..3, inspect(stats)
    assert stats.queries > 0
    assert stats.lock_queries > 0
  end

  defp assert_retry_scope(fixture, stats, actor) do
    Enum.each(fixture.removed_steps, &assert_missing(ChatMessageStep, &1.id, actor))
    assert fixture.source.message.id in Map.fetch!(stats.locked_ids, "chat_messages")

    Enum.each(fixture.removed_steps, fn step ->
      assert step.id in Map.fetch!(stats.locked_ids, "chat_message_steps")
    end)

    assert Ash.get!(ChatMessageStep, fixture.source.step.id, actor: actor)
    assert Ash.get!(Chat, fixture.retained_fork.id, actor: actor)
    assert Ash.get!(Chat, fixture.independent_fork.id, actor: actor)

    retained =
      fixture.descendants ++
        fixture.siblings ++ fixture.fork_history ++ [fixture.independent_source]

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
    locked = Map.get(stats.locked_ids, table, []) |> MapSet.new()
    unexpected = MapSet.intersection(locked, MapSet.new(ids))
    assert MapSet.size(unexpected) == 0, "Unexpected #{table} row locks: #{inspect(unexpected)}"
  end

  defp assert_missing(resource, id, actor) do
    assert {:error, %Ash.Error.Invalid{}} = Ash.get(resource, id, actor: actor)
  end

  # Public helpers let the asset-only before harness reuse identical fixtures and measurement.
  @doc false
  def history!(actor, count, chat \\ nil, parent_id \\ nil) do
    chat = chat || create_chat!(actor)

    {anchors, _parent} =
      Enum.map_reduce(1..count, parent_id, fn _, parent_id ->
        message =
          ChatMessage
          |> Ash.Changeset.for_create(
            :add_message,
            %{chat_id: chat.id, role: :assistant, parent_id: parent_id},
            actor: actor
          )
          |> Ash.create!(actor: actor)

        step = create_step!(message, 1, actor)

        item =
          ChatMessageItem
          |> Ash.Changeset.for_create(
            :create,
            %{chat_message_step_id: step.id, sequence: 1, type: :tool_call},
            actor: actor
          )
          |> Ash.create!(actor: actor)

        {%{chat: chat, message: message, step: step, item: item}, message.id}
      end)

    {chat, anchors}
  end

  @doc false
  def retry_fixture!(actor, removed_count, retained_count) do
    {chat, [source]} = history!(actor, 1)
    removed_steps = Enum.map(2..(removed_count + 1), &create_step!(source.message, &1, actor))
    {_chat, descendants} = history!(actor, retained_count, chat, source.message.id)
    {_chat, siblings} = history!(actor, retained_count, chat)
    retained_fork = linked_chat!(source, actor)
    {_chat, fork_history} = history!(actor, retained_count, retained_fork)
    {_other_chat, [independent_source]} = history!(actor, 1)
    independent_fork = linked_chat!(independent_source, actor)

    %{
      source: source,
      removed_steps: removed_steps,
      descendants: descendants,
      siblings: siblings,
      retained_fork: retained_fork,
      fork_history: fork_history,
      independent_fork: independent_fork,
      independent_source: independent_source
    }
  end

  defp create_chat!(actor, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_step!(message, sequence, actor) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_id: message.id, sequence: sequence},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  @doc false
  def linked_chat!(source, actor) do
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
      fork_task: "Cleanup performance fixture"
    })
    |> Ash.create!(actor: actor)
  end

  @doc false
  def measure(label, operation) do
    table = :ets.new(__MODULE__, [:ordered_set, :public])
    handler = {__MODULE__, make_ref()}
    root = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [@sql_event, @plan_event, @discover_event],
        &__MODULE__.handle_event/4,
        %{root: root, table: table}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    old_counters = start_old_counters()
    started = System.monotonic_time()

    try do
      result = operation.()
      elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      :telemetry.detach(handler)
      events = :ets.tab2list(table) |> Enum.map(&elem(&1, 1))
      queries = for {:sql, query} <- events, do: query
      locks = Enum.filter(queries, & &1.lock?)

      locked_ids =
        Enum.reduce(locks, %{}, fn query, acc ->
          Map.update(acc, query.source, query.ids, &Enum.uniq(&1 ++ query.ids))
        end)

      stats = %{
        label: label,
        elapsed_ms: Float.round(elapsed / 1000, 2),
        queries: length(queries),
        nonlocking_selects: Enum.count(queries, &(&1.select? and not &1.lock?)),
        lock_queries: length(locks),
        locked_ids: locked_ids,
        plans: Enum.count(events, &match?({:plan, _}, &1)),
        discoveries: Enum.count(events, &match?({:discover, _}, &1)),
        old_lock_entries: old_count(old_counters, :lock!),
        old_discoveries: old_count(old_counters, :plan)
      }

      IO.puts("CLEANUP_PERF " <> Jason.encode!(stats))

      if path = System.get_env("IC_CLEANUP_PERF_OUTPUT") do
        File.write!(path, Jason.encode!(stats) <> "\n", [:append])
      end

      {result, stats}
    after
      :telemetry.detach(handler)
      stop_old_counters(old_counters)
      :ets.delete(table)
    end
  end

  @doc false
  def handle_event(event, _measurements, metadata, %{root: root, table: table}) do
    callers = Process.get(:"$callers", [])
    # Ash may execute queries in a Task. Ecto can emit in its caller's process as well.
    if self() == root or root in callers or metadata[:caller] == root do
      value =
        case event do
          @sql_event ->
            sql = IO.iodata_to_binary(metadata.query)

            source =
              case Regex.run(~r/FROM "([a-z_]+)"/, sql) do
                [_, source] -> source
                _ -> metadata[:source] || "other"
              end

            lock? = Regex.match?(~r/FOR (?:NO KEY UPDATE|UPDATE|KEY SHARE|SHARE)/, sql)

            {:sql,
             %{
               source: source,
               select?: String.starts_with?(sql, "SELECT"),
               lock?: lock?,
               ids: if(lock?, do: result_ids(metadata[:result]), else: [])
             }}

          @plan_event ->
            {:plan, metadata}

          @discover_event ->
            {:discover, metadata}
        end

      :ets.insert(table, {System.unique_integer([:positive, :monotonic]), value})
    end
  end

  defp result_ids({:ok, %{columns: columns, rows: rows}})
       when is_list(columns) and is_list(rows) do
    case Enum.find_index(columns, &(&1 == "id")) do
      nil -> []
      index -> Enum.map(rows, &Enum.at(&1, index))
    end
  end

  defp result_ids(_), do: []

  defp start_old_counters do
    if System.get_env("IC_CLEANUP_PERF_OLD_COUNTERS") == "1" do
      module = IntellectualClub.Chat.LinkedForkCleanupLocks
      Enum.each([:lock!, :plan], &:erlang.trace_pattern({module, &1, 3}, true, [:call_count]))
      module
    end
  end

  defp old_count(nil, _function), do: nil

  defp old_count(module, function) do
    case :erlang.trace_info({module, function, 3}, :call_count) do
      {:call_count, count} when is_integer(count) -> count
      _ -> nil
    end
  end

  defp stop_old_counters(nil), do: :ok

  defp stop_old_counters(module) do
    Enum.each([:lock!, :plan], &:erlang.trace_pattern({module, &1, 3}, false, [:call_count]))
  end
end
