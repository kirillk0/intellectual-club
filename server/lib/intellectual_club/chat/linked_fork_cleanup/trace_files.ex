defmodule IntellectualClub.Chat.LinkedForkCleanup.TraceFiles do
  @moduledoc """
  Releases the logical files owned by a whole chat's database-cascaded trace.

  The parent operation already holds FOR UPDATE on every target step. Lock its
  items before reading contents: a concurrent INSERT into contents needs KEY SHARE
  on its item, not on the step. Also lock file-less contents so an UPDATE cannot
  attach a new file between capture and the cascade. Request pins refer directly
  to the fenced steps. Each level gets a fresh READ COMMITTED snapshot after the
  preceding fence; only IDs are projected, never provider or media payloads.
  """

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStepRequestFile
  }

  alias IntellectualClub.Chat.LinkedForkCleanup.Operation
  alias IntellectualClub.Files.File

  require Ash.Query

  def capture!(chat_id, %{id: owner_id} = actor, operation) do
    %{owner_id: ^owner_id} = Operation.record!(operation, Chat, chat_id, actor)
    state = Operation.state!(operation, actor)

    step_ids =
      for {id, %{chat_id: ^chat_id}} <- state.plan.deleted.messages,
          step <- Map.get(state.steps, id, []),
          do: step.id

    file_ids = capture_file_ids!(step_ids, actor)

    # Keep privileged file IDs inside a short-lived, transaction-local capability;
    # delete! cannot be used to destroy a caller-supplied list of logical files.
    Operation.update!(operation, actor, fn state ->
      put_in(state, [Access.key(:captured_trace_files, %{}), chat_id], file_ids)
    end)

    {operation, chat_id}
  end

  def delete!({operation, chat_id}, actor) do
    state = Operation.state!(operation, actor)
    file_ids = Map.fetch!(state.captured_trace_files, chat_id)

    Operation.update!(
      operation,
      actor,
      &update_in(&1.captured_trace_files, fn files -> Map.delete(files, chat_id) end)
    )

    delete_files!(file_ids, actor)
  end

  defp capture_file_ids!([], _actor), do: []

  defp capture_file_ids!(step_ids, actor) do
    item_ids =
      ChatMessageItem
      |> Ash.Query.filter(chat_message_step_id in ^step_ids and owner_id == ^actor.id)
      |> locked_ids!(:id, actor)

    contents =
      if item_ids == [] do
        []
      else
        ChatMessageContent
        |> Ash.Query.filter(chat_message_item_id in ^item_ids and owner_id == ^actor.id)
        |> locked_ids!(:file_id, actor)
      end

    pins =
      ChatMessageStepRequestFile
      |> Ash.Query.filter(chat_message_step_id in ^step_ids)
      |> locked_ids!(:file_id, actor)

    (contents ++ pins) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp locked_ids!(query, field, actor) do
    query
    |> Ash.Query.select([field])
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(actor: actor, authorize?: true)
    |> Enum.map(&Map.fetch!(&1, field))
  end

  defp delete_files!([], _actor), do: []

  defp delete_files!(ids, actor) do
    # No filesystem mutation or payload lock here. GC after the outer commit
    # takes the same SHA lock as uploads/duplication, and rechecks all remaining
    # logical files. A GC racing *before* commit still sees the original rows.
    result =
      File
      |> Ash.Query.filter(id in ^ids)
      |> Ash.bulk_destroy!(:destroy, %{},
        actor: actor,
        authorize?: true,
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true,
        select: [:sha256]
      )

    case result do
      %Ash.BulkResult{status: :success, records: files} ->
        files |> Enum.map(& &1.sha256) |> Enum.uniq()

      %Ash.BulkResult{errors: errors} ->
        raise Ash.Error.to_error_class(errors)
    end
  end
end
