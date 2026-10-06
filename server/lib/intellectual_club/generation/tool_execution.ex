defmodule IntellectualClub.Generation.ToolExecution do
  @moduledoc """
  Coordinates tool cancellation at explicit execution boundaries.

  Tool tasks start protected while resolving local data and writing receipts.
  External waits opt into interruption; returning to protected work requires
  permission from the generation worker, so cancellation cannot dispatch a
  late database operation.
  """

  @owner_key {__MODULE__, :owner}
  @call_key {__MODULE__, :call_item_id}

  def run(owner, fun), do: run(owner, nil, fun)

  def run(owner, call_item_id, fun) when is_pid(owner) and is_function(fun, 0) do
    Process.put(@owner_key, owner)
    Process.put(@call_key, call_item_id)

    try do
      checkpoint()
      {:completed, fun.()}
    catch
      :throw, {__MODULE__, :canceled} -> :canceled
    after
      Process.delete(@owner_key)
      Process.delete(@call_key)
    end
  end

  def checkpoint, do: transition(:protected)

  def interruptible(fun) when is_function(fun, 0) do
    transition(:interruptible)

    try do
      fun.()
    after
      checkpoint()
    end
  end

  defp transition(phase) do
    case Process.get(@owner_key) do
      owner when is_pid(owner) ->
        command =
          case Process.get(@call_key) do
            nil -> {:tool_execution_phase, self(), phase}
            id -> {:tool_execution_phase, self(), phase, id}
          end

        case GenServer.call(owner, command, :infinity) do
          :ok -> :ok
          :canceled -> throw({__MODULE__, :canceled})
        end

      nil ->
        :ok
    end
  end
end
