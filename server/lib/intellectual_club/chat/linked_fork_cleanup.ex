defmodule IntellectualClub.Chat.LinkedForkCleanup do
  @moduledoc """
  Executes one explicitly scoped cleanup plan per deletion or retry operation.

  Discovery and reference cleanup run once. Nested Ash destroys keep authorization
  and normal content/file actions, but receive a transaction-local capability and
  never rediscover dependencies. PostgreSQL transaction outcome, not row absence,
  defers runtime cancellation until the outermost commit, including nested callers.
  """
  use Ash.Domain, validate_config_inclusion?: false

  alias Ash.Changeset
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep, ChatUploadSession}

  alias IntellectualClub.Chat.LinkedForkCleanup.{
    Bookmark,
    GenerationEvent,
    Operation,
    TransactionOutcome
  }

  alias IntellectualClub.Chat.LinkedForkCleanupLocks
  alias IntellectualClub.Files.UploadStaging
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.Llm.LlmUsageRecord

  require Ash.Query
  require Logger

  resources do
    resource(Bookmark)
    resource(GenerationEvent)
    resource(TransactionOutcome)
  end

  @operation_key :linked_fork_cleanup_operation

  @doc "Runs inside an existing transaction, before any mutation or row fence."
  def with_scope(scope, actor, fun) when is_function(fun, 1) do
    case LinkedForkCleanupLocks.prepare!(scope, actor) do
      nil -> raise ArgumentError, "Cleanup target no longer exists"
      plan -> Operation.run(plan, fun)
    end
  end

  def context(operation), do: %{@operation_key => operation}

  @doc false
  def retry_steps!(operation, message_id, from_sequence, actor) do
    plan = Operation.state!(operation, actor).plan

    unless plan.scope == {:steps, message_id, from_sequence} do
      raise ArgumentError, "Cleanup plan does not match the retry range"
    end

    plan.deleted.steps
    |> Map.values()
    |> Enum.filter(&(&1.chat_message_id == message_id and &1.sequence >= from_sequence))
    |> Enum.sort_by(& &1.sequence, :desc)
  end

  @doc false
  def around_destroy(changeset, callback) do
    actor = changeset.context[:private][:actor]

    if is_nil(actor) or actor.id != changeset.data.owner_id do
      callback.(
        Changeset.add_error(changeset, message: "Only the owner can clean up linked forks")
      )
    else
      case Map.get(changeset.context, @operation_key) do
        nil ->
          with_scope(scope(changeset), actor, fn operation ->
            callback.(Changeset.put_context(changeset, @operation_key, operation))
          end)

        operation ->
          Operation.record!(operation, changeset.resource, changeset.data.id, actor)
          callback.(changeset)
      end
    end
  rescue
    error in ArgumentError -> {:error, Ash.Error.to_error_class(error)}
  end

  defp scope(%{resource: Chat, data: record}), do: {:chat, record.id}
  defp scope(%{resource: ChatMessageStep, data: record}), do: {:step, record.id}

  defp scope(%{resource: ChatMessage, action: %{name: :destroy_with_children}, data: record}),
    do: {:message_tree, record.id}

  defp scope(%{resource: ChatMessage, data: record}), do: {:message, record.id}

  @doc false
  def prepare(changeset) do
    actor = changeset.context[:private][:actor]
    operation = Map.fetch!(changeset.context, @operation_key)
    Operation.record!(operation, changeset.resource, changeset.data.id, actor)
    prepare_references!(operation, actor)

    if changeset.resource == ChatMessageStep do
      state = Operation.state!(operation, actor)

      state.linked
      |> Map.get(changeset.data.id, [])
      |> Enum.each(&destroy!(&1, :destroy, operation, actor))
    end

    changeset
  rescue
    error in ArgumentError -> Changeset.add_error(changeset, message: Exception.message(error))
  end

  @doc false
  def cascade(changeset, opts) do
    operation = Map.fetch!(changeset.context, @operation_key)
    actor = changeset.context[:private][:actor]
    state = Operation.state!(operation, actor)
    relationship = Keyword.fetch!(opts, :relationship)
    action = Keyword.get(opts, :action, :destroy)

    records =
      case {changeset.resource, relationship} do
        {Chat, :root_messages} -> Map.get(state.roots, changeset.data.id, [])
        {ChatMessage, :children} -> Map.get(state.children, changeset.data.id, [])
        {ChatMessage, :steps} -> Map.get(state.steps, changeset.data.id, []) |> Enum.reverse()
      end

    Enum.each(records, &destroy!(&1, action, operation, actor))
    changeset
  end

  def destroy!(record, action, operation, actor) do
    record
    |> Changeset.for_destroy(action, %{}, actor: actor, context: context(operation))
    |> Ash.destroy!(actor: actor)
  end

  defp prepare_references!(operation, actor) do
    state = Operation.state!(operation, actor)

    unless state.prepared? do
      plan = state.plan
      chats = Map.keys(plan.deleted.chats)
      messages = Map.keys(plan.deleted.messages)
      steps = Map.keys(plan.deleted.steps)
      items = MapSet.to_list(plan.item_ids)

      if chats != [] or messages != [] do
        Chat
        |> Ash.Query.filter(id in ^chats or last_message_id in ^messages)
        |> Ash.bulk_update!(:set_last_message, %{last_message_id: nil}, bulk_opts(actor))
        |> ensure_bulk_success!()
      end

      destroy_references!(Bookmark, :chat_message_id, messages, actor)
      destroy_references!(GenerationEvent, :chat_message_id, messages, actor)
      uploads = destroy_references!(ChatUploadSession, :chat_id, chats, actor)

      if chats != [] or messages != [] or steps != [] do
        LlmUsageRecord
        |> Ash.Query.filter(
          chat_id in ^chats or chat_message_id in ^messages or chat_message_step_id in ^steps
        )
        |> Ash.bulk_update!(
          :detach_deleted_references,
          %{chat_ids: chats, message_ids: messages, step_ids: steps},
          bulk_opts(actor)
        )
        |> ensure_bulk_success!()
      end

      task_filter = [
        or: [
          source_chat_id: [in: chats],
          target_chat_id: [in: chats],
          source_message_id: [in: messages],
          lifecycle_message_id: [in: messages],
          source_step_id: [in: steps],
          source_tool_call_item_id: [in: items]
        ]
      ]

      tasks =
        BackgroundTask
        |> Ash.Query.filter(^task_filter)
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.lock(:for_update)
        |> Ash.read!(actor: actor)

      task_ids = Enum.map(tasks, & &1.id)

      if task_ids != [] do
        BackgroundTask
        |> Ash.Query.filter(id in ^task_ids)
        |> Ash.bulk_update!(
          :detach_deleted_references,
          %{chat_ids: chats, message_ids: messages, step_ids: steps, item_ids: items},
          bulk_opts(actor)
        )
        |> ensure_bulk_success!()
      end

      worker_messages =
        plan.deleted.messages
        |> Map.values()
        |> Enum.filter(
          &(&1.status == :generating or is_pid(GenerationSupervisor.generation_worker_pid(&1.id)))
        )
        |> Enum.map(& &1.id)

      work = %{
        message_ids: worker_messages,
        task_ids: tasks |> Enum.filter(&(&1.status in [:queued, :running])) |> Enum.map(& &1.id),
        upload_ids: Enum.map(uploads, & &1.external_id)
      }

      Operation.update!(operation, actor, &%{&1 | prepared?: true, work: work})
    end
  end

  defp bulk_opts(actor),
    do: [
      actor: actor,
      return_records?: true,
      return_errors?: true,
      strategy: [:atomic, :stream],
      max_concurrency: 1
    ]

  defp ensure_bulk_success!(%Ash.BulkResult{status: :success} = result), do: result

  defp ensure_bulk_success!(%Ash.BulkResult{errors: errors}),
    do: raise(Ash.Error.to_error_class(errors))

  defp destroy_references!(_resource, _field, [], _actor), do: []

  defp destroy_references!(resource, field, ids, actor) do
    result =
      resource
      |> Ash.Query.filter(^[{field, [in: ids]}])
      |> Ash.bulk_destroy!(:destroy, %{}, bulk_opts(actor))
      |> ensure_bulk_success!()

    result.records || []
  end

  @doc false
  def schedule_after_delete(changeset) do
    actor = changeset.context[:private][:actor]
    operation = Map.fetch!(changeset.context, @operation_key)
    state = Operation.state!(operation, actor)
    barrier = {changeset.resource, changeset.data.id}

    if not state.scheduled? and state.plan.barrier == barrier do
      Operation.update!(operation, actor, &%{&1 | scheduled?: true})
      schedule_work(barrier, actor, state.work)
    end
  end

  defp schedule_work(_barrier, _actor, %{message_ids: [], task_ids: [], upload_ids: []}), do: :ok

  defp schedule_work(_barrier, actor, work) do
    transaction_id = TransactionOutcome.capture!(actor)

    case Task.Supervisor.start_child(
           IntellectualClub.BackgroundTasks.ExecutionSupervisor,
           fn -> stop_after_commit(transaction_id, actor, work) end
         ) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("Unable to schedule linked fork cleanup: #{inspect(reason)}")
    end
  end

  defp stop_after_commit(transaction_id, actor, work) do
    # A root may be inserted and deleted by the same transaction, or removed by
    # another operation after this one rolls back. Only this xid's commit allows
    # side effects; polling holds no row lock or open transaction.
    if TransactionOutcome.await_committed?(transaction_id, actor) do
      Enum.each(work.upload_ids, fn external_id ->
        external_id |> UploadStaging.chat_upload_path() |> UploadStaging.cleanup_path()
      end)

      Enum.each(work.message_ids, fn message_id ->
        GenerationSupervisor.with_generation_start_lock(message_id, fn ->
          case GenerationSupervisor.generation_worker_pid(message_id) do
            pid when is_pid(pid) -> Worker.cancel(pid)
            nil -> :ok
          end
        end)
      end)

      Enum.each(work.task_ids, fn task_id ->
        case BackgroundTasks.cancel(task_id, actor.id) do
          {:ok, _snapshot} ->
            :ok

          {:error, reason} ->
            Logger.warning("Linked fork task cancellation failed: #{inspect(reason)}")
        end
      end)
    end
  rescue
    error -> Logger.error("Linked fork cleanup commit check failed: #{Exception.message(error)}")
  end
end
