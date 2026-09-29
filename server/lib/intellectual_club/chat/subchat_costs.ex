defmodule IntellectualClub.Chat.SubchatCosts do
  @moduledoc """
  Authorized, phase-cached provider costs for a source message's subchat tree.

  The ledger remains authoritative. A child usage update alone intentionally does
  not invalidate a snapshot; parent step boundaries or an explicit reload do.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.SubchatCostCache
  alias IntellectualClub.Llm.LlmUsageRecord

  require Ash.Query

  @root_relation_kinds [:fork, :spawn]
  @descendant_relation_kinds [:handoff, :fork, :spawn]
  @max_descendant_chats 10_000
  @chunk_size 100
  @step_revision_fields [
    :id,
    :chat_message_id,
    :sequence,
    :status,
    :response_final,
    :finished_at,
    :updated_at
  ]

  @type summary :: %{
          costs_by_message_id: %{optional(integer()) => float()},
          revision: String.t()
        }

  @doc """
  Returns phase snapshots for all readable source messages in a chat.

  Full state loads pass `refresh?: true`; idle polling uses the default cached
  snapshots. Authorization of the root and descendant chats is request-local.
  """
  @spec summary(integer(), map(), keyword()) :: summary()
  def summary(root_chat_id, actor, opts \\ [])

  def summary(root_chat_id, %{id: actor_id} = actor, opts)
      when is_integer(root_chat_id) and is_integer(actor_id) do
    roots = direct_subchat_roots([root_chat_id], nil, actor)
    message_ids = roots |> Enum.map(& &1.parent_message_id) |> Enum.uniq()
    messages = readable_messages(message_ids, actor)
    summarize(messages, roots, actor, opts)
  end

  def summary(_root_chat_id, _actor, _opts), do: empty_summary()

  @doc """
  Returns costs only for the requested messages, never for their sibling trees.

  `steps` may contain the already-authorized persisted step summaries read by the
  BFF in this request. Runtime streaming snapshots must not be passed as steps.
  """
  @spec for_messages([map()], map(), keyword()) :: summary()
  def for_messages(messages, actor, opts \\ [])

  def for_messages(messages, %{id: actor_id} = actor, opts)
      when is_list(messages) and is_integer(actor_id) do
    message_ids = messages |> Enum.map(& &1.id) |> Enum.uniq()
    messages = readable_messages(message_ids, actor)
    chat_ids = messages |> Enum.map(& &1.chat_id) |> Enum.uniq()
    roots = direct_subchat_roots(chat_ids, message_ids, actor)
    summarize(messages, roots, actor, opts)
  end

  def for_messages(_messages, _actor, _opts), do: empty_summary()

  @doc false
  def parent_revision(message, steps) do
    latest_step = Enum.max_by(steps, &{&1.sequence, &1.id}, fn -> nil end)

    step_revision =
      if latest_step do
        [
          latest_step.id,
          latest_step.sequence,
          latest_step.status,
          latest_step.response_final,
          latest_step.finished_at,
          # Active streaming/usage writes are not parent step boundaries.
          if(latest_step.status in [:done, :canceled, :error],
            do: Map.get(latest_step, :updated_at)
          )
        ]
      end

    hash([message.id, message.status, message.finished_at, step_revision])
  end

  defp summarize([], _roots, _actor, _opts), do: empty_summary()

  defp summarize(messages, roots, actor, opts) do
    message_by_id = Map.new(messages, &{&1.id, &1})

    roots =
      Enum.filter(roots, fn root ->
        case Map.get(message_by_id, root.parent_message_id) do
          %{chat_id: chat_id} -> chat_id == root.parent_chat_id
          _other -> false
        end
      end)

    sources = Map.new(roots, &{&1.id, &1.parent_message_id})
    root_chat_ids = Enum.map(messages, & &1.chat_id)

    sources =
      expand_descendants(
        roots,
        sources,
        MapSet.new(root_chat_ids ++ Map.keys(sources)),
        actor
      )

    chat_ids_by_message_id =
      Enum.group_by(sources, fn {_chat_id, message_id} -> message_id end, fn {chat_id, _id} ->
        chat_id
      end)
      |> Map.new(fn {id, ids} -> {id, Enum.sort(ids)} end)

    # Only source messages participate in the chat-wide revision. Empty trees
    # need neither a usage query nor a cache entry.
    messages = Enum.filter(messages, &Map.has_key?(chat_ids_by_message_id, &1.id))
    steps = Keyword.get_lazy(opts, :steps, fn -> read_steps(messages, actor) end)
    steps_by_message_id = Enum.group_by(steps, & &1.chat_message_id)
    actor_key = {Map.get(actor, :__struct__), actor.id}

    requests =
      Map.new(messages, fn message ->
        phase = parent_revision(message, Map.get(steps_by_message_id, message.id, []))
        scope = Map.fetch!(chat_ids_by_message_id, message.id)
        {{actor_key, message.id}, hash([phase, scope])}
      end)

    values =
      SubchatCostCache.fetch_many(
        requests,
        fn keys ->
          scopes =
            Map.new(keys, fn {_actor, id} -> {id, Map.fetch!(chat_ids_by_message_id, id)} end)

          costs = aggregate_costs(scopes, actor)
          Map.new(keys, fn {_actor, id} = key -> {key, Map.get(costs, id)} end)
        end,
        opts
      )

    costs =
      values
      |> Enum.flat_map(fn
        {{_actor, id}, cost} when is_number(cost) -> [{id, cost * 1.0}]
        _other -> []
      end)
      |> Map.new()

    revision_rows =
      requests
      |> Enum.map(fn {{_actor, id} = key, revision} -> {id, revision, Map.get(values, key)} end)
      |> Enum.sort()

    %{costs_by_message_id: costs, revision: hash(revision_rows)}
  end

  defp empty_summary, do: %{costs_by_message_id: %{}, revision: hash([])}

  defp readable_messages([], _actor), do: []

  defp readable_messages(message_ids, actor) do
    ChatMessage
    |> Ash.Query.filter(id in ^message_ids)
    |> Ash.Query.select([:id, :chat_id, :status, :finished_at])
    |> Ash.read!(actor: actor)
  end

  defp direct_subchat_roots([], _message_ids, _actor), do: []

  defp direct_subchat_roots(root_chat_ids, message_ids, actor) do
    # Re-check root chat access even when the caller supplied a previously read
    # message. Cached costs must never extend access after a share is revoked.
    readable_root_ids =
      Chat
      |> Ash.Query.filter(id in ^root_chat_ids)
      |> Ash.Query.select([:id])
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.id)

    query =
      Chat
      |> Ash.Query.filter(
        parent_chat_id in ^readable_root_ids and parent_relation_kind in ^@root_relation_kinds
      )

    query =
      if is_list(message_ids),
        do: Ash.Query.filter(query, parent_message_id in ^message_ids),
        else: Ash.Query.filter(query, not is_nil(parent_message_id))

    query
    |> Ash.Query.select([:id, :parent_chat_id, :parent_message_id])
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(@max_descendant_chats)
    |> Ash.read!(actor: actor)
  end

  defp expand_descendants([], sources, _visited, _actor), do: sources

  defp expand_descendants(_frontier, sources, _visited, _actor)
       when map_size(sources) >= @max_descendant_chats,
       do: sources

  defp expand_descendants(frontier, sources, visited, actor) do
    parent_ids = Enum.map(frontier, & &1.id)
    remaining = @max_descendant_chats - map_size(sources)

    children =
      Chat
      |> Ash.Query.filter(
        parent_chat_id in ^parent_ids and parent_relation_kind in ^@descendant_relation_kinds
      )
      |> Ash.Query.select([:id, :parent_chat_id, :parent_message_id])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(remaining)
      |> Ash.read!(actor: actor)
      |> Enum.reject(&MapSet.member?(visited, &1.id))

    next_sources =
      Enum.reduce(children, sources, fn child, acc ->
        Map.put(acc, child.id, Map.fetch!(sources, child.parent_chat_id))
      end)

    next_visited = Enum.reduce(children, visited, &MapSet.put(&2, &1.id))
    expand_descendants(children, next_sources, next_visited, actor)
  end

  defp read_steps([], _actor), do: []

  defp read_steps(messages, actor) do
    message_ids = Enum.map(messages, & &1.id)

    ChatMessageStep
    |> Ash.Query.filter(chat_message_id in ^message_ids)
    |> Ash.Query.select(@step_revision_fields)
    |> Ash.Query.distinct(:chat_message_id)
    |> Ash.Query.distinct_sort(chat_message_id: :asc, sequence: :desc, id: :desc)
    |> Ash.read!(actor: actor)
  end

  defp aggregate_costs(scopes, _actor) when map_size(scopes) == 0, do: %{}

  defp aggregate_costs(scopes, actor) when map_size(scopes) == 1 do
    [{message_id, chat_ids}] = Map.to_list(scopes)

    cost =
      LlmUsageRecord
      |> Ash.Query.filter(chat_id in ^chat_ids)
      |> Ash.sum!(:cost, actor: actor)

    %{message_id => cost}
  end

  defp aggregate_costs(scopes, actor) do
    source_by_chat_id =
      scopes
      |> Enum.flat_map(fn {message_id, ids} -> Enum.map(ids, &{&1, message_id}) end)
      |> Map.new()

    source_by_chat_id
    |> Map.keys()
    |> Enum.sort()
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce(%{}, fn chat_ids, costs ->
      # Named filtered SUMs are grouped by AshPostgres into one SQL query per
      # batch. String names avoid creating atoms from unbounded database IDs.
      aggregates =
        Enum.map(chat_ids, fn id ->
          {Integer.to_string(id), :sum, field: :cost, query: [filter: [chat_id: id]]}
        end)

      sums =
        LlmUsageRecord
        |> Ash.Query.filter(chat_id in ^chat_ids)
        |> Ash.aggregate!(aggregates, actor: actor)

      Enum.reduce(chat_ids, costs, fn id, acc ->
        case Map.get(sums, Integer.to_string(id)) do
          cost when is_number(cost) ->
            Map.update(acc, Map.fetch!(source_by_chat_id, id), cost, &(&1 + cost))

          _unknown ->
            acc
        end
      end)
    end)
  end

  defp hash(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.url_encode64(padding: false)
  end
end
