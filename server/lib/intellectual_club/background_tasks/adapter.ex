defmodule IntellectualClub.BackgroundTasks.Adapter do
  @moduledoc """
  Adapter contract for durable background operations.

  Execution runs in a supervised worker. Recovery is called once during backend
  startup for tasks that were not terminal when the backend stopped.
  """

  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  @type recovery_result ::
          :restart
          | :keep
          | :execution_lost
          | {:completed, ExecutionResult.t() | map()}
          | {:failed, term()}

  @callback execute_background(
              BackgroundTask.t(),
              ToolInstance.t(),
              String.t(),
              map(),
              ExecutionContext.t()
            ) ::
              {:ok, ExecutionResult.t() | map()}
              | {:completed, ExecutionResult.t() | map()}
              | {:waiting, map()}
              | {:running, map()}
              | {:failed, term()}
              | :canceled
              | {:error, term()}

  @callback recover_background(BackgroundTask.t()) :: recovery_result()
  @callback cancel_background(BackgroundTask.t()) :: :ok | {:error, term()}
  @callback reconcile_background(BackgroundTask.t()) ::
              {:waiting, %{generation_message_id: pos_integer(), pid: pid()}}
              | {:retry, term()}
              | {:completed, ExecutionResult.t() | map()}
              | {:failed, term()}
              | :canceled
              | {:error, term()}
  @callback reconcile_background_read_only(BackgroundTask.t()) ::
              {:waiting, %{generation_message_id: pos_integer(), pid: pid()}}
              | {:retry, term()}
              | {:completed, ExecutionResult.t() | map()}
              | {:failed, term()}
              | :canceled
              | {:error, term()}
  @callback snapshot_background(BackgroundTask.t(), String.t() | nil) ::
              :default | {:ok, map()} | {:error, term()}

  @optional_callbacks reconcile_background: 1,
                      reconcile_background_read_only: 1,
                      snapshot_background: 2
end
