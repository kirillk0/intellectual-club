defmodule IntellectualClub.BackgroundTasks.Supervisor do
  @moduledoc """
  Supervises one temporary worker per background task.
  """

  use DynamicSupervisor

  alias IntellectualClub.BackgroundTasks.Worker

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_task(Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def start_task(task_id) when is_binary(task_id) do
    spec = %{
      id: {Worker, task_id},
      start: {Worker, :start_link, [[task_id: task_id]]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:already_running, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @spec cancel_task(Ecto.UUID.t()) :: :ok | {:error, term()} | :not_found
  def cancel_task(task_id) when is_binary(task_id) do
    case Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task_id) do
      [{pid, _value}] ->
        try do
          GenServer.call(pid, :cancel, 10_000)
        catch
          :exit, _reason -> :not_found
        end

      [] ->
        :not_found
    end
  end
end
