defmodule IntellectualClub.Chat.SubchatCostSnapshotTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatShare
  alias IntellectualClub.Chat.SubchatCostCache
  alias IntellectualClub.Chat.SubchatCosts
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Llm.LlmUsageRecord

  @sql_event [:intellectual_club, :repo, :query]

  setup do
    cache = start_supervised!({SubchatCostCache, name: __MODULE__.Cache})
    %{user: actor} = user_fixture()

    provider =
      create!(LlmProvider, %{name: "Cost snapshots", type: :demo, auth_method: :api_key}, actor)

    configuration =
      create!(
        LlmConfiguration,
        %{provider_id: provider.id, model_name: "cost-snapshots", parameters: %{}, enabled: true},
        actor
      )

    bot = create!(Bot, %{name: "Cost snapshots", first_messages: []}, actor)
    root = create!(Chat, %{bot_id: bot.id, llm_configuration_id: configuration.id}, actor)
    source = source!(root, configuration, actor)
    step = step!(source, actor, :waiting_tools)
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

    create!(
      ChatMessageStep,
      %{chat_message_id: f.source.id, sequence: 2, status: :waiting_provider},
      f.actor
    )

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
    replacement = step!(f.source, f.actor, :waiting_tools)
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
    share!(f.root, group, f.actor)
    share!(f.child, group, f.actor)
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
    root_share = share!(f.root, group, f.actor)
    child_share = share!(f.child, group, f.actor)

    # A durable owner snapshot can outlive current configuration ownership.
    record_cost!(f.child, f.configuration, f.actor, 0.07, reader)
    readable = SubchatCosts.for_messages([f.source], reader, f.opts)
    assert readable.costs_by_message_id[f.source.id] == 0.07

    Ash.destroy!(child_share, actor: f.actor)
    assert SubchatCosts.for_messages([f.source], reader, f.opts).costs_by_message_id == %{}

    share!(f.child, group, f.actor)

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
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Prompt", actor: actor)

    ChatMessage
    |> Ash.Changeset.for_create(
      :create_generating_assistant,
      %{chat_id: chat.id, parent_id: user_message.id, llm_configuration_id: configuration.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp step!(source, actor, status) do
    create!(ChatMessageStep, %{chat_message_id: source.id, sequence: 1, status: status}, actor)
  end

  defp child!(parent, source, configuration, actor, kind \\ :spawn) do
    create!(
      Chat,
      %{
        bot_id: parent.bot_id,
        llm_configuration_id: configuration.id,
        parent_chat_id: parent.id,
        parent_message_id: source.id,
        parent_relation_kind: kind,
        subagent: true
      },
      actor
    )
  end

  defp record_cost!(chat, configuration, actor, cost, configuration_owner \\ nil) do
    configuration_owner = configuration_owner || actor
    message = source!(chat, configuration, actor)
    step = step!(message, actor, :done)

    record =
      create!(
        LlmUsageRecord,
        %{
          usage_user_id: actor.id,
          usage_user_id_snapshot: actor.id,
          usage_username_snapshot: actor.username,
          configuration_owner_id: configuration_owner.id,
          configuration_owner_id_snapshot: configuration_owner.id,
          llm_configuration_id: configuration.id,
          llm_configuration_id_snapshot: configuration.id,
          llm_configuration_label_snapshot: configuration.model_name,
          chat_id: chat.id,
          chat_id_snapshot: chat.id,
          chat_message_id: message.id,
          chat_message_id_snapshot: message.id,
          chat_message_step_id: step.id,
          chat_message_step_id_snapshot: step.id,
          step_sequence: step.sequence,
          occurred_at: DateTime.utc_now(),
          cost: cost
        },
        actor
      )

    {message, record}
  end

  defp share!(chat, group, actor) do
    create!(
      ChatShare,
      %{
        chat_id: chat.id,
        user_group_id: group.id,
        bot_id: chat.bot_id,
        llm_configuration_id: chat.llm_configuration_id
      },
      actor
    )
  end

  defp create!(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp update!(%ChatMessage{} = record, attrs, actor) do
    record
    |> Ash.Changeset.for_update(:set_generation_state, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp update!(record, attrs, actor) do
    record
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp assert_sum(query) do
    assert query.sql =~ ~r/\bsum\s*\(/i
    refute query.sql =~ ~r/\bselect\s+\w+\."id"/i
  end

  defp measure(fun) do
    ref = make_ref()
    handler = {__MODULE__, ref}
    :ok = :telemetry.attach(handler, @sql_event, &__MODULE__.handle_query/4, {self(), ref})

    try do
      result = fun.()
      {result, drain_queries(ref, [])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def handle_query(_event, _measurements, metadata, {pid, ref}) do
    sql = IO.iodata_to_binary(metadata.query)

    if String.starts_with?(sql, "SELECT") and String.contains?(sql, "\"llm_usage_records\"") do
      send(pid, {ref, %{sql: sql, params: metadata.params}})
    end
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, query} -> drain_queries(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
