defmodule IntellectualClub.Tools.DocumentWorker do
  @moduledoc """
  Bounded admission for document loading, extraction, and cache writes.

  Pending requests carry source callbacks, not downloaded payloads. A single
  monitored worker owns the entire operation. Heap limits are a secondary
  safeguard, not an OS memory boundary; parsers must bound their allocations.
  """
  use GenServer

  @default_memory_bytes 256 * 1024 * 1024
  @default_queue_limit 16

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def run(fun, timeout_ms, server \\ __MODULE__)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(server, {:run, fun, timeout_ms}, :infinity)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       active: nil,
       pending: [],
       queue_limit: Keyword.get(opts, :queue_limit, @default_queue_limit),
       memory_bytes: Keyword.get(opts, :memory_bytes, @default_memory_bytes)
     }}
  end

  @impl true
  def handle_call({:run, fun, timeout}, from, state) do
    if state.active != nil and length(state.pending) >= state.queue_limit do
      {:reply, {:error, :busy}, state}
    else
      id = make_ref()
      owner = Process.monitor(elem(from, 0))
      timer = Process.send_after(self(), {:deadline, id}, timeout)

      job = %{
        id: id,
        from: from,
        owner: owner,
        timer: timer,
        fun: fun,
        deadline: System.monotonic_time(:millisecond) + timeout
      }

      {:noreply, dispatch(%{state | pending: state.pending ++ [job]})}
    end
  end

  @impl true
  def handle_info({:result, pid, result}, %{active: %{pid: pid} = job} = state) do
    job = if job.cancelled, do: job, else: %{job | result: {:ok, result}}
    {:noreply, %{state | active: job}}
  end

  def handle_info({:failed, pid}, %{active: %{pid: pid} = job} = state) do
    job = if job.cancelled, do: job, else: %{job | result: {:error, :failed}}
    {:noreply, %{state | active: job}}
  end

  def handle_info({:deadline, id}, %{active: %{id: id} = job} = state) do
    Process.exit(job.pid, :kill)
    {:noreply, %{state | active: %{job | cancelled: true, result: {:error, :timeout}}}}
  end

  def handle_info({:deadline, id}, state) do
    {expired, pending} = Enum.split_with(state.pending, &(&1.id == id))
    Enum.each(expired, &finish(&1, {:error, :timeout}))
    {:noreply, %{state | pending: pending}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active: %{ref: ref} = job} = state) do
    result = job.result || {:error, if(reason == :killed, do: :memory_limit, else: :failed)}
    finish(job, result)
    {:noreply, dispatch(%{state | active: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{owner: ref} = job} = state) do
    Process.exit(job.pid, :kill)
    {:noreply, %{state | active: %{job | cancelled: true, result: {:error, :cancelled}}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {cancelled, pending} = Enum.split_with(state.pending, &(&1.owner == ref))
    Enum.each(cancelled, &finish(&1, {:error, :cancelled}))
    {:noreply, %{state | pending: pending}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{active: %{pid: pid, ref: ref}}) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp dispatch(%{active: nil, pending: [job | rest]} = state) do
    caller = elem(job.from, 0)

    cond do
      node(caller) == node() and not Process.alive?(caller) ->
        finish(job, {:error, :cancelled})
        dispatch(%{state | pending: rest})

      System.monotonic_time(:millisecond) >= job.deadline ->
        finish(job, {:error, :timeout})
        dispatch(%{state | pending: rest})

      true ->
        start_job(job, rest, state)
    end
  end

  defp dispatch(state), do: state

  defp start_job(job, rest, state) do
    manager = self()
    fun = job.fun

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          try do
            send(manager, {:result, self(), fun.()})
          catch
            # Never copy a parser exception containing the input PDF to the manager.
            _kind, _reason -> send(manager, {:failed, self()})
          end
        end,
        [
          :link,
          :monitor,
          {:max_heap_size,
           %{
             size: div(state.memory_bytes, :erlang.system_info(:wordsize)),
             kill: true,
             error_logger: false,
             include_shared_binaries: true
           }}
        ]
      )

    active =
      job |> Map.delete(:fun) |> Map.merge(%{pid: pid, ref: ref, result: nil, cancelled: false})

    %{state | active: active, pending: rest}
  end

  defp finish(job, result) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.owner, [:flush])
    GenServer.reply(job.from, result)
  end
end
