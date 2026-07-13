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
              | {:running, map()}
              | {:failed, term()}
              | :canceled
              | {:error, term()}

  @callback recover_background(BackgroundTask.t()) :: recovery_result()
  @callback cancel_background(BackgroundTask.t()) :: :ok | {:error, term()}
  @callback snapshot_background(BackgroundTask.t(), String.t() | nil) ::
              :default | {:ok, map()} | {:error, term()}

  @optional_callbacks snapshot_background: 2
end
