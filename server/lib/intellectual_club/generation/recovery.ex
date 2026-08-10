defmodule IntellectualClub.Generation.Recovery do
  @moduledoc false

  use GenServer

  require Logger

  defstruct [:task_pid, :recovery_fun, pending?: false]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def request(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, :recover)
    end
  end

  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    recovery_fun =
      Keyword.get(
        opts,
        :recovery_fun,
        &IntellectualClub.Generation.Supervisor.recover_orphaned_generations/0
      )

    {:ok, %__MODULE__{recovery_fun: recovery_fun}}
  end

  @impl true
  def handle_cast(:recover, %__MODULE__{task_pid: nil} = state) do
    {:noreply, start_recovery(state)}
  end

  def handle_cast(:recover, %__MODULE__{} = state) do
    {:noreply, %{state | pending?: true}}
  end

  @impl true
  def handle_call(:status, _from, %__MODULE__{} = state) do
    {:reply, %{running?: is_pid(state.task_pid), pending?: state.pending?}, state}
  end

  @impl true
  def handle_info({:EXIT, task_pid, reason}, %__MODULE__{task_pid: task_pid} = state) do
    if reason != :normal do
      Logger.warning("Orphaned generation recovery task exited: #{inspect(reason)}")
    end

    state = %{state | task_pid: nil}

    if state.pending? do
      {:noreply, state |> Map.put(:pending?, false) |> start_recovery()}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, %__MODULE__{} = state), do: {:noreply, state}

  defp start_recovery(%__MODULE__{} = state) do
    {:ok, task_pid} = Task.start_link(fn -> run_recovery(state.recovery_fun) end)
    %{state | task_pid: task_pid}
  end

  defp run_recovery(recovery_fun) when is_function(recovery_fun, 0) do
    recovery_fun.()
  rescue
    exception ->
      Logger.warning(
        "Failed to run orphaned generation recovery: #{Exception.message(exception)}"
      )
  catch
    :exit, reason ->
      Logger.warning("Orphaned generation recovery exited: #{inspect(reason)}")
  end
end
