defmodule IntellectualClub.Chat.LinkedForkCleanupLocks do
  @moduledoc """
  Plans one linked-fork cleanup and acquires all its row fences before mutation.

  Call `prepare!/2` inside the outer transaction, before taking any other fence.
  The order is chats, messages, then steps. Initial chat fences use FOR NO KEY
  UPDATE so a message-fenced worker can still insert its first accounting row
  whose chat FK takes KEY SHARE. Only a deleted root chat is finally upgraded to
  FOR UPDATE, after all affected generation messages have been fenced.

  Discovery follows deletion dependencies, affected task authorities and their
  ancestors using authorized Ash reads, never manager RPCs. Each discovery uses
  frontier batches and fresh caches; it does not repeatedly read accumulated
  sets or load whole chats for a single-message/step operation. Three discoveries
  detect growth while taking fences. A new earlier-order dependency fails closed
  and requires rollback/retry, rather than acquiring locks out of order.
  """

  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.LinkedForkCleanup.Plan

  require Ash.Query

  @chat_fields [:id, :owner_id, :parent_chat_id, :parent_message_id, :fork_source_step_id]
  @message_fields [:id, :owner_id, :chat_id, :parent_id, :status]
  @step_fields [:id, :owner_id, :chat_message_id, :sequence]
  @plan_event [:intellectual_club, :linked_fork_cleanup, :plan]
  @discover_event [:intellectual_club, :linked_fork_cleanup, :discover]

  @doc """
  Returns a fenced cleanup plan, or nil if its root has disappeared/is unreadable.

  Only the owner may prepare cleanup. `:message` removes just that message and
  its steps, `:message_tree` includes its physical descendants, and
  `:message_keep_children` also fences the direct children and parent without
  deleting them. `{:steps, message_id, from_sequence}` deletes only the selected
  range, retaining the message. Linked dependents are included in every scope.

  The caller must retain these locks throughout execution and must not reuse the
  plan for another operation or transaction. No mutation is performed here.
  """
  @spec prepare!(Plan.scope(), struct()) :: Plan.t() | nil
  def prepare!(scope, actor) do
    :telemetry.execute(@plan_event, %{count: 1}, %{scope: scope})
    {resource, id} = root(scope)
    require_owner_actor!(actor)

    unless Ash.DataLayer.in_transaction?(resource) do
      raise ArgumentError, "Linked fork cleanup locks require a transaction"
    end

    with %Plan{} = initial <- discover(scope, resource, id, actor),
         :ok <- lock_rows(Chat, initial.locks.chats, actor, "FOR NO KEY UPDATE"),
         %Plan{} = after_chats <- discover(scope, resource, id, actor),
         :ok <- require_subset!(after_chats.locks.chats, initial.locks.chats),
         :ok <- lock_rows(ChatMessage, after_chats.locks.messages, actor),
         %Plan{} = after_messages <- discover(scope, resource, id, actor) do
      require_subset!(after_messages.locks.chats, initial.locks.chats)
      require_subset!(after_messages.locks.messages, after_chats.locks.messages)

      # New steps discovered after waiting for a message are safe to fence now.
      # Every deleted step's owning message is already FOR UPDATE locked, so its
      # FK also prevents new step insertions while this final set is locked.
      lock_rows(ChatMessageStep, after_messages.locks.steps, actor)

      case read_root(resource, id, actor, :for_update) do
        nil -> nil
        current -> put_root(after_messages, current)
      end
    end
  end

  defp root({:chat, id}) when is_integer(id), do: {Chat, id}
  defp root({:step, id}) when is_integer(id), do: {ChatMessageStep, id}

  defp root({kind, id})
       when kind in [:message, :message_tree, :message_keep_children] and is_integer(id),
       do: {ChatMessage, id}

  defp root({:steps, id, from_sequence}) when is_integer(id) and is_integer(from_sequence),
    do: {ChatMessage, id}

  defp root(_scope), do: raise(ArgumentError, "Invalid linked fork cleanup scope")

  defp discover(scope, resource, id, actor) do
    :telemetry.execute(@discover_event, %{count: 1}, %{scope: scope})

    case read_root(resource, id, actor) do
      nil ->
        nil

      record ->
        {deleted, retained, cached_messages} = seed(scope, record, actor)
        deleted = expand_deletions(deleted, ids(deleted), actor)

        item_ids =
          read_by(ChatMessageItem, :chat_message_step_id, Map.keys(deleted.steps), actor, [:id])

        item_ids = MapSet.new(item_ids, & &1.id)

        tasks = affected_tasks(deleted, item_ids, actor)
        references = referencing_chats(deleted, item_ids, actor)

        message_ids =
          Map.keys(deleted.messages) ++
            Map.keys(retained) ++
            Enum.map(Map.values(deleted.steps), & &1.chat_message_id) ++
            Enum.flat_map(tasks, fn task ->
              [task.source_message_id, task.lifecycle_message_id, context_message_id(task)]
            end)

        chat_ids =
          Map.keys(deleted.chats) ++ Enum.flat_map(tasks, &[&1.source_chat_id, &1.target_chat_id])

        cache = %{
          chats: merge_records(deleted.chats, references),
          messages: Map.merge(cached_messages, Map.merge(deleted.messages, retained)),
          steps: deleted.steps
        }

        pending = %{
          chats: chat_ids ++ Enum.map(references, & &1.id),
          messages: message_ids,
          steps: []
        }

        ancestors = expand_ancestors(cache, pending, empty_sets(), actor)

        assert_acyclic!(
          Map.new(ancestors.messages, fn {id, message} -> {id, [message.parent_id]} end),
          Map.keys(ancestors.messages)
        )

        # A chat needing FK nilification is only a fence, not a reverse edge of
        # inherited history. Check ancestry from actual deletion/task authorities,
        # not from otherwise unrelated chats which merely reference those rows.
        logical_chat_ids =
          chat_ids ++
            Enum.flat_map(message_ids, fn id ->
              case Map.get(ancestors.messages, id) do
                nil -> []
                message -> [message.chat_id]
              end
            end)

        assert_acyclic!(chat_edges(ancestors), logical_chat_ids)

        %Plan{
          scope: scope,
          owner_id: actor.id,
          root_record: record,
          barrier: barrier(scope, record, deleted),
          deleted: deleted,
          item_ids: item_ids,
          locks: %{
            chats: id_set(ancestors.chats),
            messages: id_set(ancestors.messages),
            steps: id_set(deleted.steps)
          }
        }
    end
  end

  defp seed({:chat, _id}, chat, _actor) do
    {%{empty_records() | chats: %{chat.id => chat}}, %{}, %{}}
  end

  defp seed({:step, _id}, step, _actor) do
    {%{empty_records() | steps: %{step.id => step}}, %{}, %{}}
  end

  defp seed({:steps, _id, from_sequence}, message, actor) do
    steps =
      read(
        ChatMessageStep,
        [chat_message_id: message.id, sequence: [greater_than_or_equal: from_sequence]],
        actor,
        @step_fields
      )
      |> record_map()

    {%{empty_records() | steps: steps}, %{message.id => message}, %{}}
  end

  defp seed({:message_tree, _id}, message, actor) do
    messages =
      read_by(ChatMessage, :chat_id, [message.chat_id], actor, @message_fields)
      |> record_map()
      |> Map.put(message.id, message)

    children = Enum.group_by(Map.values(messages), & &1.parent_id, & &1.id)
    descendants = descendant_ids!([message.id], children, MapSet.new())
    deleted = %{empty_records() | messages: Map.take(messages, MapSet.to_list(descendants))}
    {deleted, %{}, messages}
  end

  defp seed({:message_keep_children, _id}, message, actor) do
    relatives =
      read(
        ChatMessage,
        [chat_id: message.chat_id, or: [parent_id: message.id, id: message.parent_id]],
        actor,
        @message_fields
      )
      |> record_map()

    {%{empty_records() | messages: %{message.id => message}}, relatives, %{}}
  end

  defp seed({:message, _id}, message, _actor) do
    {%{empty_records() | messages: %{message.id => message}}, %{}, %{}}
  end

  defp descendant_ids!([], _children, visited), do: visited

  defp descendant_ids!(frontier, children, visited) do
    next =
      Enum.flat_map(frontier, fn id ->
        if MapSet.member?(visited, id), do: cycle_error!()
        Map.get(children, id, [])
      end)

    descendant_ids!(next, children, MapSet.union(visited, MapSet.new(frontier)))
  end

  defp expand_deletions(deleted, frontier, actor) do
    messages = read_by(ChatMessage, :chat_id, frontier.chats, actor, @message_fields)
    new_messages = Enum.reject(messages, &Map.has_key?(deleted.messages, &1.id))
    message_ids = frontier.messages ++ Enum.map(new_messages, & &1.id)
    steps = read_by(ChatMessageStep, :chat_message_id, message_ids, actor, @step_fields)
    new_steps = Enum.reject(steps, &Map.has_key?(deleted.steps, &1.id))
    step_ids = frontier.steps ++ Enum.map(new_steps, & &1.id)
    chats = read_by(Chat, :fork_source_step_id, step_ids, actor, @chat_fields)
    new_chats = Enum.reject(chats, &Map.has_key?(deleted.chats, &1.id))

    deleted = %{
      chats: merge_records(deleted.chats, new_chats),
      messages: merge_records(deleted.messages, new_messages),
      steps: merge_records(deleted.steps, new_steps)
    }

    case new_chats do
      [] ->
        deleted

      _ ->
        expand_deletions(
          deleted,
          %{chats: Enum.map(new_chats, & &1.id), messages: [], steps: []},
          actor
        )
    end
  end

  defp affected_tasks(deleted, item_ids, actor) do
    read_references(
      BackgroundTask,
      [
        source_chat_id: Map.keys(deleted.chats),
        target_chat_id: Map.keys(deleted.chats),
        source_message_id: Map.keys(deleted.messages),
        lifecycle_message_id: Map.keys(deleted.messages),
        source_step_id: Map.keys(deleted.steps),
        source_tool_call_item_id: MapSet.to_list(item_ids)
      ],
      actor,
      [
        :id,
        :source_chat_id,
        :target_chat_id,
        :source_message_id,
        :lifecycle_message_id,
        :execution_context
      ]
    )
  end

  defp referencing_chats(deleted, item_ids, actor) do
    read_references(
      Chat,
      [
        parent_chat_id: Map.keys(deleted.chats),
        parent_message_id: Map.keys(deleted.messages),
        parent_tool_call_item_id: MapSet.to_list(item_ids),
        last_message_id: Map.keys(deleted.messages)
      ],
      actor,
      @chat_fields
    )
  end

  defp expand_ancestors(cache, pending, seen, actor) do
    {chats, cache, seen} = take_frontier(:chats, pending.chats, cache, seen, actor)
    step_ids = pending.steps ++ Enum.map(chats, & &1.fork_source_step_id)
    {steps, cache, seen} = take_frontier(:steps, step_ids, cache, seen, actor)

    message_ids =
      pending.messages ++
        Enum.map(chats, & &1.parent_message_id) ++
        Enum.map(steps, & &1.chat_message_id)

    {messages, cache, seen} = take_frontier(:messages, message_ids, cache, seen, actor)

    if chats == [] and steps == [] and messages == [] do
      Map.new(cache, fn {kind, records} ->
        {kind, Map.take(records, MapSet.to_list(seen[kind]))}
      end)
    else
      next = %{
        chats: Enum.map(chats, & &1.parent_chat_id) ++ Enum.map(messages, & &1.chat_id),
        messages: [],
        steps: []
      }

      expand_ancestors(cache, next, seen, actor)
    end
  end

  defp take_frontier(kind, pending, cache, seen, actor) do
    frontier = pending |> integer_ids() |> Enum.reject(&MapSet.member?(seen[kind], &1))
    missing = Enum.reject(frontier, &Map.has_key?(cache[kind], &1))
    {resource, fields} = resource_fields(kind)
    records = merge_records(cache[kind], read_by(resource, :id, missing, actor, fields))
    seen = Map.update!(seen, kind, &MapSet.union(&1, MapSet.new(frontier)))
    {Map.values(Map.take(records, frontier)), Map.put(cache, kind, records), seen}
  end

  defp resource_fields(:chats), do: {Chat, @chat_fields}
  defp resource_fields(:messages), do: {ChatMessage, @message_fields}
  defp resource_fields(:steps), do: {ChatMessageStep, @step_fields}

  defp chat_edges(ancestors) do
    Map.new(ancestors.chats, fn {id, chat} ->
      source_chat_id =
        with %{chat_message_id: message_id} <- Map.get(ancestors.steps, chat.fork_source_step_id),
             %{chat_id: source_chat_id} <- Map.get(ancestors.messages, message_id) do
          source_chat_id
        else
          _ -> nil
        end

      {id, [chat.parent_chat_id, source_chat_id]}
    end)
  end

  defp barrier({:steps, message_id, _from_sequence}, _record, deleted) do
    deleted.steps
    |> Map.values()
    |> Enum.filter(&(&1.chat_message_id == message_id))
    |> Enum.min_by(&{&1.sequence, &1.id}, fn -> nil end)
    |> case do
      nil -> nil
      step -> {ChatMessageStep, step.id}
    end
  end

  defp barrier(scope, record, _deleted) do
    {resource, _id} = root(scope)
    {resource, record.id}
  end

  defp put_root(plan, record) do
    {resource, _id} = root(plan.scope)

    kind =
      Map.fetch!(%{Chat => :chats, ChatMessage => :messages, ChatMessageStep => :steps}, resource)

    deleted =
      if Map.has_key?(plan.deleted[kind], record.id) do
        Map.update!(plan.deleted, kind, &Map.put(&1, record.id, record))
      else
        plan.deleted
      end

    %{plan | root_record: record, deleted: deleted}
  end

  defp context_message_id(%{execution_context: context}) when is_map(context) do
    context["assistant_message_id"] || context[:assistant_message_id] ||
      context["message_id"] || context[:message_id]
  end

  defp context_message_id(_task), do: nil

  defp read_root(resource, id, actor, lock \\ nil) do
    query = Ash.Query.filter(resource, id == ^id)
    query = if lock, do: Ash.Query.lock(query, lock), else: query

    case Ash.read_one!(query, actor: actor, timeout: :infinity) do
      nil -> nil
      %{owner_id: owner_id} = record when owner_id == actor.id -> record
      _ -> owner_error!()
    end
  end

  defp read(resource, filter, actor, fields) do
    resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.select(fields)
    |> Ash.read!(actor: actor)
  end

  defp read_by(resource, field, ids, actor, fields) do
    case integer_ids(ids) do
      [] -> []
      ids -> read(resource, [{field, [in: ids]}], actor, fields)
    end
  end

  defp read_references(resource, references, actor, fields) do
    filters = for {field, [_ | _] = ids} <- references, do: {field, [in: ids]}
    if filters == [], do: [], else: read(resource, [or: filters], actor, fields)
  end

  defp lock_rows(resource, ids, actor, lock \\ :for_update) do
    unless MapSet.size(ids) == 0 do
      ids = Enum.sort(ids)

      resource
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(lock)
      |> Ash.read!(actor: actor, timeout: :infinity)
    end

    :ok
  end

  defp require_owner_actor!(%{id: id}) when is_integer(id), do: :ok
  defp require_owner_actor!(_actor), do: owner_error!()

  defp owner_error!,
    do: raise(ArgumentError, "Only the owner can lock linked fork cleanup dependencies")

  defp cycle_error!, do: raise(ArgumentError, "Cycle in linked fork cleanup dependencies")
  defp empty_records, do: %{chats: %{}, messages: %{}, steps: %{}}
  defp empty_sets, do: %{chats: MapSet.new(), messages: MapSet.new(), steps: MapSet.new()}
  defp record_map(records), do: Map.new(records, &{&1.id, &1})
  defp integer_ids(ids), do: ids |> Enum.filter(&is_integer/1) |> Enum.uniq()
  defp ids(records), do: Map.new(records, fn {kind, records} -> {kind, Map.keys(records)} end)
  defp id_set(records), do: records |> Map.keys() |> MapSet.new()

  defp merge_records(records, additions) do
    Enum.reduce(additions, records, &Map.put(&2, &1.id, &1))
  end

  defp require_subset!(current, locked) do
    unless MapSet.subset?(current, locked) do
      raise ArgumentError, "Linked fork cleanup dependencies changed; retry the transaction"
    end

    :ok
  end

  defp assert_acyclic!(edges, roots) do
    Enum.reduce(roots, MapSet.new(), &visit!(&1, edges, &2, MapSet.new()))
    :ok
  end

  defp visit!(id, edges, done, path) do
    cond do
      MapSet.member?(path, id) ->
        cycle_error!()

      is_nil(id) or not Map.has_key?(edges, id) or MapSet.member?(done, id) ->
        done

      true ->
        path = MapSet.put(path, id)
        done = Enum.reduce(Map.fetch!(edges, id), done, &visit!(&1, edges, &2, path))
        MapSet.put(done, id)
    end
  end
end
