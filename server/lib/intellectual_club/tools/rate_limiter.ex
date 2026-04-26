defmodule IntellectualClub.Tools.RateLimiter do
  @moduledoc """
  In-memory global rate limiter for tool instance executions.

  The configured RPS limit is persisted on the tool instance, but this process
  keeps only transient queue and cooldown state. Restarting the application
  starts rate limiting from an empty state.
  """

  use GenServer

  @max_backlog_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec await_slot(map()) :: :ok | {:error, :busy}
  def await_slot(tool_instance) when is_map(tool_instance) do
    case limit_config(tool_instance) do
      :unlimited ->
        :ok

      {:limited, tool_instance_id, cooldown_ms} ->
        try do
          GenServer.call(__MODULE__, {:await_slot, tool_instance_id, cooldown_ms}, :infinity)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset, 5_000)
  end

  @doc false
  def queue_length(tool_instance_id) when is_integer(tool_instance_id) do
    GenServer.call(__MODULE__, {:queue_length, tool_instance_id}, 5_000)
  end

  @impl true
  def init(_opts) do
    {:ok, %{instances: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    state.instances
    |> Map.values()
    |> Enum.each(fn instance ->
      if instance.timer_ref, do: Process.cancel_timer(instance.timer_ref)

      instance.queue
      |> :queue.to_list()
      |> Enum.each(fn entry -> Process.demonitor(entry.monitor_ref, [:flush]) end)
    end)

    {:reply, :ok, %{instances: %{}, monitors: %{}}}
  end

  def handle_call({:queue_length, tool_instance_id}, _from, state) do
    instance = Map.get(state.instances, tool_instance_id)
    count = if instance, do: :queue.len(instance.queue), else: 0
    {:reply, count, state}
  end

  def handle_call({:await_slot, tool_instance_id, cooldown_ms}, from, state) do
    now_ms = now_ms()

    instance =
      state.instances
      |> Map.get(tool_instance_id, new_instance())
      |> Map.put(:cooldown_ms, cooldown_ms)

    cond do
      :queue.len(instance.queue) == 0 and slot_available?(instance, now_ms) ->
        instance = %{instance | last_started_ms: now_ms}
        {:reply, :ok, put_instance(state, tool_instance_id, instance)}

      estimated_wait_ms(instance, now_ms) > @max_backlog_ms ->
        {:reply, {:error, :busy}, put_instance(state, tool_instance_id, instance)}

      true ->
        {caller_pid, _tag} = from
        monitor_ref = Process.monitor(caller_pid)
        entry = %{from: from, monitor_ref: monitor_ref}

        instance = %{instance | queue: :queue.in(entry, instance.queue)}
        state = %{state | monitors: Map.put(state.monitors, monitor_ref, tool_instance_id)}
        {instance, state} = ensure_timer(instance, state, tool_instance_id, now_ms)

        {:noreply, put_instance(state, tool_instance_id, instance)}
    end
  end

  @impl true
  def handle_info({:grant_slot, tool_instance_id}, state) do
    now_ms = now_ms()

    case Map.get(state.instances, tool_instance_id) do
      nil ->
        {:noreply, state}

      instance ->
        instance = %{instance | timer_ref: nil}

        case :queue.out(instance.queue) do
          {{:value, entry}, queue} ->
            Process.demonitor(entry.monitor_ref, [:flush])
            GenServer.reply(entry.from, :ok)

            instance = %{instance | queue: queue, last_started_ms: now_ms}
            state = %{state | monitors: Map.delete(state.monitors, entry.monitor_ref)}
            {instance, state} = ensure_timer(instance, state, tool_instance_id, now_ms)

            {:noreply, put_instance(state, tool_instance_id, instance)}

          {:empty, _queue} ->
            {:noreply, put_instance(state, tool_instance_id, instance)}
        end
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {tool_instance_id, monitors} ->
        instance =
          state.instances
          |> Map.get(tool_instance_id, new_instance())
          |> remove_queue_entry(monitor_ref)

        {:noreply, put_instance(%{state | monitors: monitors}, tool_instance_id, instance)}
    end
  end

  defp limit_config(tool_instance) do
    tool_instance_id = Map.get(tool_instance, :id) || Map.get(tool_instance, "id")
    rps_limit = Map.get(tool_instance, :rps_limit) || Map.get(tool_instance, "rps_limit")

    cond do
      not (is_integer(tool_instance_id) and tool_instance_id > 0) ->
        :unlimited

      not (is_number(rps_limit) and rps_limit > 0) ->
        :unlimited

      true ->
        cooldown_ms =
          rps_limit
          |> then(&(1000 / &1))
          |> Float.ceil()
          |> trunc()
          |> max(1)

        {:limited, tool_instance_id, cooldown_ms}
    end
  end

  defp new_instance do
    %{last_started_ms: nil, cooldown_ms: 0, queue: :queue.new(), timer_ref: nil}
  end

  defp put_instance(state, tool_instance_id, instance) do
    %{state | instances: Map.put(state.instances, tool_instance_id, instance)}
  end

  defp slot_available?(%{last_started_ms: nil}, _now_ms), do: true

  defp slot_available?(%{last_started_ms: last_started_ms, cooldown_ms: cooldown_ms}, now_ms) do
    now_ms - last_started_ms >= cooldown_ms
  end

  defp estimated_wait_ms(instance, now_ms) do
    remaining_cooldown_ms(instance, now_ms) + :queue.len(instance.queue) * instance.cooldown_ms
  end

  defp remaining_cooldown_ms(%{last_started_ms: nil}, _now_ms), do: 0

  defp remaining_cooldown_ms(
         %{last_started_ms: last_started_ms, cooldown_ms: cooldown_ms},
         now_ms
       ) do
    max(cooldown_ms - (now_ms - last_started_ms), 0)
  end

  defp ensure_timer(%{timer_ref: timer_ref} = instance, state, _tool_instance_id, _now_ms)
       when not is_nil(timer_ref) do
    {instance, state}
  end

  defp ensure_timer(instance, state, tool_instance_id, _now_ms) do
    if :queue.len(instance.queue) == 0 do
      {instance, state}
    else
      delay_ms = remaining_cooldown_ms(instance, now_ms())
      timer_ref = Process.send_after(self(), {:grant_slot, tool_instance_id}, delay_ms)
      {%{instance | timer_ref: timer_ref}, state}
    end
  end

  defp remove_queue_entry(instance, monitor_ref) do
    queue =
      instance.queue
      |> :queue.to_list()
      |> Enum.reject(&(&1.monitor_ref == monitor_ref))
      |> Enum.reduce(:queue.new(), fn entry, acc -> :queue.in(entry, acc) end)

    %{instance | queue: queue}
  end

  defp now_ms do
    System.monotonic_time(:millisecond)
  end
end
