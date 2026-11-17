defmodule IntellectualClub.Tools.Lua.Sandbox do
  @moduledoc """
  Bounded fresh processes, with admission control and caller-death cleanup.

  The coordinator never runs user code. A result is released only after its worker
  has exited, including on timeout. No script is retried.
  """
  use GenServer
  alias IntellectualClub.Tools.Lua.Limits

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def run(owner_id, fun) do
    GenServer.call(__MODULE__, {:run, owner_id, fun}, :infinity)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:run, owner, fun}, from, jobs) do
    if map_size(jobs) >= Limits.get(:max_concurrent) or
         Enum.count(jobs, fn {_pid, job} -> job.owner == owner end) >= Limits.get(:max_per_user) do
      {:reply, {:error, "Lua execution capacity reached; try again later."}, jobs}
    else
      coordinator = self()
      caller_monitor = Process.monitor(elem(from, 0))

      heap = Limits.heap_limit()

      {pid, monitor} =
        :erlang.spawn_opt(
          fn -> send(coordinator, {:result, self(), fun.()}) end,
          [:link, :monitor, {:max_heap_size, heap}]
        )

      timer = Process.send_after(self(), {:timeout, pid}, Limits.get(:timeout_ms))

      job = %{
        owner: owner,
        from: from,
        monitor: monitor,
        caller_monitor: caller_monitor,
        timer: timer,
        result: nil
      }

      {:noreply, Map.put(jobs, pid, job)}
    end
  end

  @impl true
  def handle_info({:result, pid, result}, jobs) do
    {:noreply,
     update_job(jobs, pid, fn job -> if job.result, do: job, else: %{job | result: result} end)}
  end

  def handle_info({:timeout, pid}, jobs) do
    if Map.has_key?(jobs, pid), do: Process.exit(pid, :kill)
    {:noreply, update_job(jobs, pid, &%{&1 | result: {:error, "Lua execution timed out."}})}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, jobs) do
    case Map.get(jobs, pid) do
      %{monitor: ^monitor} = job ->
        Process.cancel_timer(job.timer)
        Process.demonitor(job.caller_monitor, [:flush])

        GenServer.reply(
          job.from,
          job.result || {:error, "Lua worker stopped (memory limit or cancellation)."}
        )

        {:noreply, Map.delete(jobs, pid)}

      _ ->
        Enum.each(jobs, fn {worker, job} ->
          if job.caller_monitor == monitor, do: Process.exit(worker, :kill)
        end)

        {:noreply, jobs}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, jobs), do: {:noreply, jobs}

  @impl true
  def terminate(_reason, jobs) do
    Enum.each(jobs, fn {pid, _job} -> Process.exit(pid, :kill) end)
  end

  defp update_job(jobs, pid, fun) do
    if Map.has_key?(jobs, pid), do: Map.update!(jobs, pid, fun), else: jobs
  end
end
