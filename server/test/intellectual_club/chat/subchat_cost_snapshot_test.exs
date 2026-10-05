defmodule IntellectualClub.Chat.SubchatCostSnapshotTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Chat.ForkFixtures,
    only: [update_record!: 3, update_record!: 4]

  alias IntellectualClub.Chat.{ChatMessage, SubchatCostCache, SubchatCosts}
  alias IntellectualClub.SqlCapture

  setup do
    cache = start_supervised!({SubchatCostCache, name: __MODULE__.Cache})
    %{user: actor} = user_fixture()
    configuration = create_configuration!(actor, model_name: "cost-snapshots")
    bot = create_bot!(actor)
    root = create_chat!(actor, bot_id: bot.id, llm_configuration_id: configuration.id)
    source = source!(root, configuration, actor)
    step = create_step!(actor, source, status: :waiting_tools)
    child = child!(root, source, configuration, actor)

    %{
      actor: actor,
      configuration: configuration,
      root: root,
      source: source,
      step: step,
      child: child,
      opts: [cache: cache]
    }
  end

  test "repeated polls reuse unknown snapshots and ignore child completion", f do
    {first, [query]} = measure(fn -> poll(f) end)
    assert_sum(query)
    assert first.costs_by_message_id[f.source.id] == nil

    record_cost!(f.child, f.configuration, f.actor, 0.03)

    for _poll <- 1..3 do
      {cached, queries} = measure(fn -> poll(f) end)
      assert queries == []
      assert cached == first
    end

    {fresh, [query]} = measure(fn -> poll(f, refresh?: true) end)
    assert_sum(query)
    assert fresh.costs_by_message_id[f.source.id] == 0.03
    assert fresh.revision != first.revision

    {cached, []} = measure(fn -> SubchatCosts.summary(f.root.id, f.actor, f.opts) end)
    assert cached == fresh
  end

  test "step finalization refreshes without changing step count", f do
    initial = poll(f)
    record_cost!(f.child, f.configuration, f.actor, 0.02)

    update!(
      f.step,
      %{status: :done, response_final: true, finished_at: DateTime.utc_now()},
      f.actor
    )

    {final, [query]} = measure(fn -> poll(f) end)
    assert_sum(query)
    assert final.costs_by_message_id[f.source.id] == 0.02
    assert final.revision != initial.revision
    assert {final, []} == measure(fn -> poll(f) end)
  end

  test "parent terminal transition refreshes an unchanged last step", f do
    update!(f.step, %{status: :done, finished_at: DateTime.utc_now()}, f.actor)
    initial = poll(f)
    record_cost!(f.child, f.configuration, f.actor, 0.04)
    update!(f.source, %{status: :done}, f.actor)

    {final, [query]} = measure(fn -> poll(f) end)
    assert_sum(query)
    assert final.costs_by_message_id[f.source.id] == 0.04
    assert final.revision != initial.revision
    assert {final, []} == measure(fn -> poll(f) end)
  end

  test "a new parent step is a boundary, not just a terminal transition", f do
    initial = poll(f)
    record_cost!(f.child, f.configuration, f.actor, 0.05)

    create_step!(f.actor, f.source, sequence: 2, status: :waiting_provider)

    {next, [query]} = measure(fn -> poll(f) end)
    assert_sum(query)
    assert next.costs_by_message_id[f.source.id] == 0.05
    assert next.revision != initial.revision
  end

  test "retry with a replacement id at the same sequence refreshes", f do
    initial = poll(f)
    record_cost!(f.child, f.configuration, f.actor, 0.06)

    # This child has no tool/step anchor, so destroying the step retains it.
    Ash.destroy!(f.step, actor: f.actor)
    replacement = create_step!(f.actor, f.source, status: :waiting_tools)
    assert replacement.sequence == f.step.sequence
    refute replacement.id == f.step.id

    {retried, [query]} = measure(fn -> poll(f) end)
    assert_sum(query)
    assert retried.costs_by_message_id[f.source.id] == 0.06
    assert retried.revision != initial.revision
    assert {retried, []} == measure(fn -> poll(f) end)
  end

  test "a single message poll sums only its subtree and ignores direct handoffs", f do
    {child_message, _record} = record_cost!(f.child, f.configuration, f.actor, 0.01)
    nested = child!(f.child, child_message, f.configuration, f.actor, :handoff)
    record_cost!(nested, f.configuration, f.actor, 0.02)

    sibling_source = source!(f.root, f.configuration, f.actor)
    sibling = child!(f.root, sibling_source, f.configuration, f.actor)
    record_cost!(sibling, f.configuration, f.actor, 5.0)

    direct_handoff = child!(f.root, f.source, f.configuration, f.actor, :handoff)
    record_cost!(direct_handoff, f.configuration, f.actor, 7.0)
    record_cost!(f.root, f.configuration, f.actor, 11.0)

    {summary, [query]} = measure(fn -> poll(f) end)
    assert_sum(query)
    assert_in_delta summary.costs_by_message_id[f.source.id], 0.03, 0.000_001
    assert Map.keys(summary.costs_by_message_id) == [f.source.id]
    assert Enum.sort([f.child.id, nested.id]) in query.params
  end

  test "full snapshots batch SUMs and cache known zero separately from unknown", f do
    record_cost!(f.child, f.configuration, f.actor, 0.0)
    other_source = source!(f.root, f.configuration, f.actor)
    other_child = child!(f.root, other_source, f.configuration, f.actor)
    record_cost!(other_child, f.configuration, f.actor, nil)

    {full, [query]} =
      measure(fn -> SubchatCosts.summary(f.root.id, f.actor, [refresh?: true] ++ f.opts) end)

    assert_sum(query)
    assert length(Regex.scan(~r/\bsum\s*\(/i, query.sql)) == 2
    assert full.costs_by_message_id[f.source.id] == 0.0
    assert full.costs_by_message_id[other_source.id] == nil
    assert {full, []} == measure(fn -> SubchatCosts.summary(f.root.id, f.actor, f.opts) end)
    assert {_, []} = measure(fn -> poll(f) end)
  end

  test "actor caches never reuse an owner's known zero for a shared reader", f do
    %{user: reader} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [f.actor, reader]})
    share_chat!(f.actor, f.root, group)
    share_chat!(f.actor, f.child, group)
    record_cost!(f.child, f.configuration, f.actor, 0.0)

    {owner_summary, [_query]} = measure(fn -> poll(f) end)
    assert owner_summary.costs_by_message_id[f.source.id] == 0.0

    {reader_summary, [query]} =
      measure(fn -> SubchatCosts.for_messages([f.source], reader, f.opts) end)

    assert_sum(query)
    assert reader_summary.costs_by_message_id[f.source.id] == nil
    refute owner_summary == reader_summary

    assert {reader_summary, []} ==
             measure(fn -> SubchatCosts.for_messages([f.source], reader, f.opts) end)

    assert {owner_summary, []} == measure(fn -> poll(f) end)
  end

  test "cached totals do not survive descendant or root access revocation", f do
    %{user: reader} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [f.actor, reader]})
    root_share = share_chat!(f.actor, f.root, group)
    child_share = share_chat!(f.actor, f.child, group)

    # A durable owner snapshot can outlive current configuration ownership.
    record_cost!(f.child, f.configuration, f.actor, 0.07, reader)
    readable = SubchatCosts.for_messages([f.source], reader, f.opts)
    assert readable.costs_by_message_id[f.source.id] == 0.07

    Ash.destroy!(child_share, actor: f.actor)
    assert SubchatCosts.for_messages([f.source], reader, f.opts).costs_by_message_id == %{}

    share_chat!(f.actor, f.child, group)

    assert SubchatCosts.for_messages([f.source], reader, f.opts).costs_by_message_id[f.source.id] ==
             0.07

    Ash.destroy!(root_share, actor: f.actor)
    assert SubchatCosts.for_messages([f.source], reader, f.opts).costs_by_message_id == %{}
    assert SubchatCosts.summary(f.root.id, reader, f.opts).costs_by_message_id == %{}
  end

  test "parent revision ignores active usage timestamps but includes terminal ones", f do
    step = Map.from_struct(f.step)
    later = DateTime.add(step.updated_at, 1, :second)
    revision = SubchatCosts.parent_revision(f.source, [step])
    assert revision == SubchatCosts.parent_revision(f.source, [%{step | updated_at: later}])

    terminal = %{step | status: :done}

    refute SubchatCosts.parent_revision(f.source, [terminal]) ==
             SubchatCosts.parent_revision(f.source, [%{terminal | updated_at: later}])
  end

  defp poll(f, extra_opts \\ []) do
    SubchatCosts.for_messages([f.source], f.actor, Keyword.merge(f.opts, extra_opts))
  end

  defp source!(chat, configuration, actor) do
    create_generating_message!(actor, chat,
      user_text: "Prompt",
      llm_configuration_id: configuration.id
    )
  end

  defp child!(parent, source, configuration, actor, kind \\ :spawn) do
    create_subchat!(actor, parent, kind, %{
      bot_id: parent.bot_id,
      llm_configuration_id: configuration.id,
      parent_message_id: source.id
    })
  end

  defp record_cost!(chat, configuration, actor, cost, configuration_owner \\ nil) do
    owner = configuration_owner || actor
    message = source!(chat, configuration, actor)
    step = create_step!(actor, message, status: :done)

    record =
      create_usage_record!(actor, %{chat: chat, message: message, step: step}, %{
        configuration_owner_id: owner.id,
        configuration_owner_id_snapshot: owner.id,
        llm_configuration_id: configuration.id,
        llm_configuration_id_snapshot: configuration.id,
        llm_configuration_label_snapshot: configuration.model_name,
        cost: cost
      })

    {message, record}
  end

  defp update!(%ChatMessage{} = message, attrs, actor),
    do: update_record!(actor, message, attrs, :set_generation_state)

  defp update!(record, attrs, actor), do: update_record!(actor, record, attrs)

  defp assert_sum(query) do
    assert query.sql =~ ~r/\bsum\s*\(/i
    refute query.sql =~ ~r/\bselect\s+\w+\."id"/i
  end

  # Usage SUM queries issued by `fun` (including its tasks).
  defp measure(fun) do
    {result, capture} = SqlCapture.measure(fun)
    {result, Enum.filter(capture.queries, &(&1.select? and &1.sql =~ ~s("llm_usage_records")))}
  end
end
