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
      work: nil,
      children: group(plan.deleted.messages, & &1.parent_id),
      steps: group(plan.deleted.steps, & &1.chat_message_id),
      dependent_chats: group(plan.deleted.chats, &deletion_parent(&1, plan.deleted))
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

  # A whole chat's trace disappears inside PostgreSQL, so its anchor steps do
  # not run Ash hooks. Visit forks of those steps before deleting the chat.
  # For partial deletions the anchor step still owns its ordinary destroy hook.
  defp deletion_parent(chat, deleted) do
    case deleted.steps[chat.fork_source_step_id] do
      nil ->
        {Chat, chat.parent_chat_id}

      step ->
        message = deleted.messages[step.chat_message_id]

        if message && Map.has_key?(deleted.chats, message.chat_id),
          do: {Chat, message.chat_id},
          else: {ChatMessageStep, step.id}
    end
  end

  defp group(records, key_fun) do
    records
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.group_by(key_fun)
  end
end
