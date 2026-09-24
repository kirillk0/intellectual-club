defmodule IntellectualClub.Chat.LinkedForkCleanup.Operation do
  @moduledoc """
  Lexically scoped capability for an explicitly passed, locked cleanup plan.

  The process dictionary only verifies the lifetime of this capability and tracks
  once-only work. It is not an implicit plan cache: callers must pass the handle,
  and it expires on every exit, including exceptions and transaction rollbacks.
  Cascades run synchronously in the same transaction and process.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep

  defstruct [:token, :owner_id, :pid]

  def run(plan, fun) when is_function(fun, 1) do
    require_transaction!()
    operation = %__MODULE__{token: make_ref(), owner_id: plan.owner_id, pid: self()}

    state = %{
      plan: plan,
      prepared?: false,
      scheduled?: false,
      work: %{message_ids: [], task_ids: [], upload_ids: []},
      roots: group(plan.deleted.messages, & &1.chat_id, &is_nil(&1.parent_id)),
      children: group(plan.deleted.messages, & &1.parent_id),
      steps: group(plan.deleted.steps, & &1.chat_message_id),
      linked: group(plan.deleted.chats, & &1.fork_source_step_id)
    }

    Process.put(key(operation), state)

    try do
      fun.(operation)
    after
      Process.delete(key(operation))
    end
  end

  def state!(%__MODULE__{owner_id: owner_id, pid: pid} = operation, %{id: owner_id})
      when pid == self() do
    require_transaction!()

    case Process.get(key(operation)) do
      %{plan: _} = state -> state
      _ -> raise ArgumentError, "Cleanup operation is no longer active"
    end
  end

  def state!(_operation, _actor), do: raise(ArgumentError, "Invalid cleanup operation")

  def update!(operation, actor, fun) do
    state = state!(operation, actor)
    Process.put(key(operation), fun.(state))
    :ok
  end

  def record!(operation, resource, id, actor) do
    state = state!(operation, actor)

    field =
      case resource do
        Chat -> :chats
        ChatMessage -> :messages
        ChatMessageStep -> :steps
      end

    case Map.fetch(state.plan.deleted[field], id) do
      {:ok, record} -> record
      :error -> raise ArgumentError, "Record is outside the cleanup operation"
    end
  end

  defp key(operation), do: {__MODULE__, operation.token}

  defp require_transaction! do
    unless Ash.DataLayer.in_transaction?(Chat) do
      raise ArgumentError, "Cleanup operation requires a transaction"
    end
  end

  defp group(records, key_fun, include? \\ fn _ -> true end) do
    records
    |> Map.values()
    |> Enum.filter(include?)
    |> Enum.sort_by(& &1.id)
    |> Enum.group_by(key_fun)
  end
end
