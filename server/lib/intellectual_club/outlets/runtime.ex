defmodule IntellectualClub.Outlets.Runtime do
  @moduledoc """
  In-memory outlet runtime transport.

  This process keeps, per outlet tool instance:
  - runner presence (online/last seen)
  - a FIFO queue of pending calls
  - a map of running calls
  - at most one long-poll waiter for `/api/outlet/poll/`
  - result waiters for server-side `execute()` calls

  Tool calls are NOT persisted: if the server restarts, pending/running calls are lost.
  Pairing requests are persisted separately in the database.
  """

  use GenServer

  alias IntellectualClub.Outlets.Config

  @sweep_interval_ms 1_000

  @runner_disconnected_error "Runner disconnected."
  @runner_session_replaced_error "Runner session replaced before completion."

  @type tool_instance :: %{id: integer(), config: map()} | map()

  @type poll_task :: %{
          call_id: String.t(),
          function: String.t(),
          arguments: map()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    state = %{
      instances: %{},
      waiter_index: %{}
    }

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, state}
  end

  @spec poll(tool_instance(), map()) ::
          {:ok, %{status: String.t(), runner_id: String.t(), tasks: list(poll_task())}}
          | {:error, :runner_already_active}
  def poll(tool_instance, payload) when is_map(tool_instance) and is_map(payload) do
    cfg = Config.from_tool_instance(tool_instance)
    timeout_ms = poll_call_timeout_ms(cfg, payload)
    GenServer.call(__MODULE__, {:poll, tool_instance, payload}, timeout_ms)
  end

  @spec complete(tool_instance(), map()) ::
          :ok | {:error, :not_found | :runner_already_active}
  def complete(tool_instance, payload) when is_map(tool_instance) and is_map(payload) do
    GenServer.call(__MODULE__, {:complete, tool_instance, payload}, 10_000)
  end

  @spec enqueue_and_wait(tool_instance(), String.t(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def enqueue_and_wait(tool_instance, function_name, args, execution_context \\ nil)
      when is_map(tool_instance) and is_binary(function_name) and is_map(args) do
    GenServer.call(
      __MODULE__,
      {:enqueue_and_wait, tool_instance, function_name, args, execution_context},
      :infinity
    )
  end

  @spec enqueue_if_absent(tool_instance(), String.t(), map()) :: :ok | :already_present
  def enqueue_if_absent(tool_instance, function_name, args, execution_context \\ nil)
      when is_map(tool_instance) and is_binary(function_name) and is_map(args) do
    GenServer.call(
      __MODULE__,
      {:enqueue_if_absent, tool_instance, function_name, args, execution_context},
      5_000
    )
  end

  @spec fetch_running_call(tool_instance(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch_running_call(tool_instance, call_id)
      when is_map(tool_instance) and is_binary(call_id) do
    GenServer.call(__MODULE__, {:fetch_running_call, tool_instance, call_id}, 5_000)
  end

  @spec online?(tool_instance()) :: boolean()
  def online?(tool_instance) when is_map(tool_instance) do
    try do
      GenServer.call(__MODULE__, {:online?, tool_instance}, 5_000)
    catch
      :exit, _reason -> false
    end
  end

  @impl true
  def handle_call({:online?, tool_instance}, _from, state) do
    tool_instance_id = tool_instance.id
    cfg = Config.from_tool_instance(tool_instance)
    now_ms = now_ms()

    instance = get_instance(state, tool_instance_id, cfg)
    online = runner_online?(instance, now_ms)
    state = put_instance(state, tool_instance_id, instance)
    {:reply, online, state}
  end

  def handle_call({:poll, tool_instance, payload}, from, state) do
    tool_instance_id = tool_instance.id
    cfg = Config.from_tool_instance(tool_instance)
    now_ms = now_ms()

    instance = get_instance(state, tool_instance_id, cfg)

    runner_id = normalize_string(payload, "runner_id", default: Ecto.UUID.generate())

    runner_session_id =
      normalize_string(payload, "runner_session_id", default: runner_id)

    metadata =
      case Map.get(payload, "metadata", Map.get(payload, :metadata)) do
        %{} = m -> m
        _ -> %{}
      end

    case touch_runner(
           instance,
           state,
           tool_instance_id,
           runner_id,
           runner_session_id,
           now_ms,
           metadata
         ) do
      {:error, :runner_already_active, instance, state} ->
        state = put_instance(state, tool_instance_id, instance)
        {:reply, {:error, :runner_already_active}, state}

      {:ok, instance, state} ->
        {capacity, max_wait_ms} =
          normalize_poll_params(instance, payload, cfg, runner_id, runner_session_id)

        {claimed, instance} =
          claim_tasks(instance, capacity, runner_id, runner_session_id, now_ms)

        tasks = Enum.map(claimed, &task_payload/1)

        cond do
          tasks != [] ->
            state = put_instance(state, tool_instance_id, instance)
            {:reply, {:ok, %{status: "ok", runner_id: runner_id, tasks: tasks}}, state}

          capacity <= 0 or max_wait_ms <= 0 ->
            state = put_instance(state, tool_instance_id, instance)
            {:reply, {:ok, %{status: "idle", runner_id: runner_id, tasks: []}}, state}

          true ->
            {instance, state, prev_waiter} = pop_poll_waiter(instance, state, tool_instance_id)
            maybe_reply_prev_poll(prev_waiter)

            {instance, state} =
              register_poll_waiter(
                instance,
                state,
                tool_instance_id,
                from,
                runner_id,
                runner_session_id,
                capacity,
                max_wait_ms
              )

            state = put_instance(state, tool_instance_id, instance)
            {:noreply, state}
        end
    end
  end

  def handle_call(
        {:enqueue_and_wait, tool_instance, function_name, args, execution_context},
        from,
        state
      ) do
    tool_instance_id = tool_instance.id
    cfg = Config.from_tool_instance(tool_instance)
    now_ms = now_ms()

    instance = get_instance(state, tool_instance_id, cfg)

    if runner_online?(instance, now_ms) do
      call_id = Ecto.UUID.generate()

      call = %{
        call_id: call_id,
        function_name: function_name,
        arguments: args || %{},
        execution_context: execution_context,
        status: :queued,
        enqueued_at_ms: now_ms
      }

      {instance, state} = register_call_waiter(instance, state, tool_instance_id, call_id, from)
      instance = %{instance | pending: instance.pending ++ [call]}
      {instance, state} = maybe_deliver_tasks(instance, state, tool_instance_id, now_ms)

      state = put_instance(state, tool_instance_id, instance)
      {:noreply, state}
    else
      state = put_instance(state, tool_instance_id, instance)
      {:reply, {:error, "Runner is offline."}, state}
    end
  end

  def handle_call(
        {:enqueue_if_absent, tool_instance, function_name, args, execution_context},
        _from,
        state
      ) do
    tool_instance_id = tool_instance.id
    cfg = Config.from_tool_instance(tool_instance)
    now_ms = now_ms()

    instance = get_instance(state, tool_instance_id, cfg)

    if call_present?(instance, function_name) do
      state = put_instance(state, tool_instance_id, instance)
      {:reply, :already_present, state}
    else
      call = %{
        call_id: Ecto.UUID.generate(),
        function_name: function_name,
        arguments: args || %{},
        execution_context: execution_context,
        status: :queued,
        enqueued_at_ms: now_ms
      }

      instance = %{instance | pending: instance.pending ++ [call]}
      {instance, state} = maybe_deliver_tasks(instance, state, tool_instance_id, now_ms)
      state = put_instance(state, tool_instance_id, instance)
      {:reply, :ok, state}
    end
  end

  def handle_call({:fetch_running_call, tool_instance, call_id}, _from, state) do
    tool_instance_id = tool_instance.id
    cfg = Config.from_tool_instance(tool_instance)
    instance = get_instance(state, tool_instance_id, cfg)

    case Map.get(instance.running, call_id) do
      nil ->
        {:reply, {:error, :not_found}, put_instance(state, tool_instance_id, instance)}

      call ->
        {:reply, {:ok, call}, put_instance(state, tool_instance_id, instance)}
    end
  end

  def handle_call({:complete, tool_instance, payload}, _from, state) do
    tool_instance_id = tool_instance.id
    cfg = Config.from_tool_instance(tool_instance)
    now_ms = now_ms()

    instance = get_instance(state, tool_instance_id, cfg)

    runner_id = normalize_string(payload, "runner_id", default: Ecto.UUID.generate())
    runner_session_id = normalize_string(payload, "runner_session_id", default: runner_id)

    metadata =
      case Map.get(payload, "metadata", Map.get(payload, :metadata)) do
        %{} = m -> m
        _ -> %{}
      end

    case touch_runner(
           instance,
           state,
           tool_instance_id,
           runner_id,
           runner_session_id,
           now_ms,
           metadata
         ) do
      {:error, :runner_already_active, instance, state} ->
        state = put_instance(state, tool_instance_id, instance)
        {:reply, {:error, :runner_already_active}, state}

      {:ok, instance, state} ->
        call_id = normalize_string(payload, "call_id", default: "")

        case Map.fetch(instance.running, call_id) do
          :error ->
            state = put_instance(state, tool_instance_id, instance)
            {:reply, {:error, :not_found}, state}

          {:ok, _call} ->
            status =
              payload
              |> Map.get("status", Map.get(payload, :status, "done"))
              |> to_string()
              |> String.trim()
              |> case do
                "error" -> "error"
                _ -> "done"
              end

            result_text =
              payload
              |> Map.get("result_text", Map.get(payload, :result_text, ""))
              |> to_string()

            error_text =
              payload
              |> Map.get("error_text", Map.get(payload, :error_text, ""))
              |> to_string()

            result_raw =
              case Map.get(payload, "result_raw", Map.get(payload, :result_raw)) do
                %{} = m -> m
                nil -> %{}
                other -> %{"result" => other}
              end

            result_media =
              case Map.get(payload, "result_media", Map.get(payload, :result_media)) do
                list when is_list(list) -> Enum.filter(list, &is_map/1)
                _ -> []
              end

            result_artifacts =
              case Map.get(payload, "result_artifacts", Map.get(payload, :result_artifacts)) do
                list when is_list(list) -> Enum.filter(list, &is_map/1)
                _ -> []
              end

            {waiter, instance, state} =
              pop_call_waiter(instance, state, tool_instance_id, call_id)

            instance = %{instance | running: Map.delete(instance.running, call_id)}

            if waiter do
              reply =
                if status == "done" do
                  {:ok,
                   %{
                     text: result_text,
                     raw: result_raw,
                     media: result_media,
                     artifacts: result_artifacts
                   }}
                else
                  {:error, error_text |> blank_to_default("Outlet call failed.")}
                end

              GenServer.reply(waiter.from, reply)
            end

            state = put_instance(state, tool_instance_id, instance)
            {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_info({:poll_timeout, tool_instance_id, poll_id}, state) do
    case Map.get(state.instances, tool_instance_id) do
      nil ->
        {:noreply, state}

      instance ->
        case instance.poll_waiter do
          %{id: ^poll_id} ->
            {instance, state, waiter} = pop_poll_waiter(instance, state, tool_instance_id)

            if waiter do
              GenServer.reply(
                waiter.from,
                {:ok, %{status: "idle", runner_id: waiter.runner_id, tasks: []}}
              )
            end

            state = put_instance(state, tool_instance_id, instance)
            {:noreply, state}

          _other ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.get(state.waiter_index, monitor_ref) do
      nil ->
        {:noreply, state}

      {:poll, tool_instance_id, poll_id} ->
        {state, _dropped?} =
          drop_poll_waiter_by_ref(state, tool_instance_id, poll_id, monitor_ref)

        {:noreply, state}

      {:call, tool_instance_id, call_id} ->
        state = drop_call_waiter_by_ref(state, tool_instance_id, call_id, monitor_ref)
        {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    now_ms = now_ms()

    {instances, waiter_index} =
      Enum.reduce(state.instances, {state.instances, state.waiter_index}, fn {tool_instance_id,
                                                                              instance},
                                                                             {instances_acc,
                                                                              waiter_index_acc} ->
        cfg = instance.config
        grace_ms = seconds_to_ms(cfg.disconnect_grace_seconds)

        {instance, waiter_index_acc} =
          cond do
            instance.runner == nil ->
              {instance, waiter_index_acc}

            runner_online?(instance, now_ms) ->
              instance = put_in(instance.runner.offline_since_ms, nil)
              {instance, waiter_index_acc}

            is_nil(instance.runner.offline_since_ms) ->
              instance = put_in(instance.runner.offline_since_ms, now_ms)
              {instance, waiter_index_acc}

            now_ms - instance.runner.offline_since_ms >= grace_ms ->
              {instance, waiter_index_acc} =
                fail_all_calls(
                  instance,
                  waiter_index_acc,
                  tool_instance_id,
                  @runner_disconnected_error
                )

              {instance, waiter_index_acc}

            true ->
              {instance, waiter_index_acc}
          end

        instances_acc = Map.put(instances_acc, tool_instance_id, instance)
        {instances_acc, waiter_index_acc}
      end)

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, %{state | instances: instances, waiter_index: waiter_index}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp seconds_to_ms(seconds) when is_number(seconds), do: trunc(seconds * 1000)

  defp poll_call_timeout_ms(%Config{} = cfg, payload) do
    raw = Map.get(payload, "max_wait_seconds", Map.get(payload, :max_wait_seconds))

    value =
      cond do
        is_number(raw) -> raw * 1.0
        is_binary(raw) -> parse_float(raw)
        true -> cfg.poll_max_wait_seconds
      end

    max_wait_seconds =
      value
      |> clamp_float(0.0, cfg.poll_max_wait_seconds)
      |> min(cfg.runner_online_timeout_seconds)

    trunc(max_wait_seconds * 1000) + 2_000
  end

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0.0
    end
  end

  defp clamp_float(value, min_value, max_value)
       when is_number(value) and is_number(min_value) and is_number(max_value) do
    value |> max(min_value) |> min(max_value) |> Kernel.*(1.0)
  end

  defp normalize_string(map, key, opts) when is_map(map) and is_binary(key) and is_list(opts) do
    default = Keyword.get(opts, :default, "")

    value =
      map
      |> Map.get(key, default)
      |> to_string()
      |> String.trim()

    if value == "" do
      to_string(default)
    else
      value
    end
  end

  defp default_instance(%Config{} = cfg) do
    %{
      config: cfg,
      runner: nil,
      pending: [],
      running: %{},
      call_waiters: %{},
      poll_waiter: nil
    }
  end

  defp get_instance(state, tool_instance_id, %Config{} = cfg) do
    Map.get(state.instances, tool_instance_id, default_instance(cfg))
    |> Map.put(:config, cfg)
  end

  defp put_instance(state, tool_instance_id, instance) do
    put_in(state.instances[tool_instance_id], instance)
  end

  defp runner_online?(instance, now_ms) do
    case instance.runner do
      %{last_seen_ms: last_seen_ms} when is_integer(last_seen_ms) ->
        timeout_ms = seconds_to_ms(instance.config.runner_online_timeout_seconds)
        now_ms - last_seen_ms <= timeout_ms

      _ ->
        false
    end
  end

  defp touch_runner(
         instance,
         state,
         tool_instance_id,
         runner_id,
         runner_session_id,
         now_ms,
         metadata
       ) do
    case instance.runner do
      nil ->
        runner = %{
          runner_id: runner_id,
          runner_session_id: runner_session_id,
          last_seen_ms: now_ms,
          offline_since_ms: nil,
          metadata: metadata || %{}
        }

        {:ok, %{instance | runner: runner}, state}

      %{runner_id: prev_id, runner_session_id: prev_session} = runner ->
        same? = to_string(prev_id) == runner_id and to_string(prev_session) == runner_session_id

        cond do
          same? ->
            runner = %{
              runner
              | last_seen_ms: now_ms,
                metadata: metadata || runner.metadata || %{}
            }

            {:ok, %{instance | runner: runner}, state}

          runner_online?(instance, now_ms) ->
            {:error, :runner_already_active, instance, state}

          true ->
            {instance, state} =
              fail_running_calls(
                instance,
                state,
                tool_instance_id,
                @runner_session_replaced_error
              )

            runner = %{
              runner_id: runner_id,
              runner_session_id: runner_session_id,
              last_seen_ms: now_ms,
              offline_since_ms: nil,
              metadata: metadata || %{}
            }

            {:ok, %{instance | runner: runner}, state}
        end
    end
  end

  defp normalize_poll_params(instance, payload, %Config{} = cfg, runner_id, runner_session_id) do
    capacity_raw = Map.get(payload, "capacity", Map.get(payload, :capacity, cfg.max_concurrency))

    capacity =
      cond do
        is_integer(capacity_raw) ->
          capacity_raw

        is_float(capacity_raw) ->
          trunc(capacity_raw)

        is_binary(capacity_raw) ->
          case Integer.parse(String.trim(capacity_raw)) do
            {parsed, ""} -> parsed
            _ -> cfg.max_concurrency
          end

        true ->
          cfg.max_concurrency
      end

    capacity = capacity |> max(0) |> min(cfg.max_concurrency)

    active =
      instance.running
      |> Enum.count(fn {_id, call} ->
        call.runner_id == runner_id and call.runner_session_id == runner_session_id
      end)

    capacity = max(0, min(capacity, cfg.max_concurrency - active))

    max_wait_raw =
      Map.get(
        payload,
        "max_wait_seconds",
        Map.get(payload, :max_wait_seconds, cfg.poll_max_wait_seconds)
      )

    max_wait_seconds =
      cond do
        is_number(max_wait_raw) -> max_wait_raw * 1.0
        is_binary(max_wait_raw) -> parse_float(max_wait_raw)
        true -> cfg.poll_max_wait_seconds
      end
      |> clamp_float(0.0, cfg.poll_max_wait_seconds)
      |> min(cfg.runner_online_timeout_seconds)

    {capacity, seconds_to_ms(max_wait_seconds)}
  end

  defp claim_tasks(instance, capacity, runner_id, runner_session_id, now_ms)
       when is_integer(capacity) and capacity >= 0 do
    if capacity <= 0 or instance.pending == [] do
      {[], instance}
    else
      {claimed, rest} = Enum.split(instance.pending, capacity)

      claimed =
        Enum.map(claimed, fn call ->
          call
          |> Map.put(:status, :running)
          |> Map.put(:started_at_ms, now_ms)
          |> Map.put(:runner_id, runner_id)
          |> Map.put(:runner_session_id, runner_session_id)
        end)

      running =
        Enum.reduce(claimed, instance.running, fn call, acc ->
          Map.put(acc, call.call_id, call)
        end)

      instance = %{instance | pending: rest, running: running}
      {claimed, instance}
    end
  end

  defp task_payload(call) do
    %{
      call_id: call.call_id,
      function: call.function_name,
      arguments: call.arguments || %{}
    }
  end

  defp call_present?(instance, function_name) when is_map(instance) and is_binary(function_name) do
    Enum.any?(instance.pending, &(&1.function_name == function_name)) or
      Enum.any?(instance.running, fn {_call_id, call} -> call.function_name == function_name end)
  end

  defp maybe_reply_prev_poll(nil), do: :ok

  defp maybe_reply_prev_poll(prev_waiter) do
    GenServer.reply(
      prev_waiter.from,
      {:ok, %{status: "idle", runner_id: prev_waiter.runner_id, tasks: []}}
    )
  end

  defp register_poll_waiter(
         instance,
         state,
         tool_instance_id,
         from,
         runner_id,
         runner_session_id,
         capacity,
         max_wait_ms
       ) do
    pid = elem(from, 0)
    monitor_ref = Process.monitor(pid)
    poll_id = make_ref()

    timer_ref =
      Process.send_after(self(), {:poll_timeout, tool_instance_id, poll_id}, max_wait_ms)

    waiter = %{
      id: poll_id,
      from: from,
      monitor_ref: monitor_ref,
      capacity: capacity,
      runner_id: runner_id,
      runner_session_id: runner_session_id,
      timer_ref: timer_ref
    }

    waiter_index = Map.put(state.waiter_index, monitor_ref, {:poll, tool_instance_id, poll_id})
    state = %{state | waiter_index: waiter_index}

    instance = %{instance | poll_waiter: waiter}
    {instance, state}
  end

  defp pop_poll_waiter(instance, state, _tool_instance_id) do
    case instance.poll_waiter do
      nil ->
        {instance, state, nil}

      waiter ->
        if waiter.timer_ref do
          _ = Process.cancel_timer(waiter.timer_ref)
        end

        Process.demonitor(waiter.monitor_ref, [:flush])
        waiter_index = Map.delete(state.waiter_index, waiter.monitor_ref)
        state = %{state | waiter_index: waiter_index}

        instance = %{instance | poll_waiter: nil}
        {instance, state, waiter}
    end
  end

  defp register_call_waiter(instance, state, tool_instance_id, call_id, from) do
    pid = elem(from, 0)
    monitor_ref = Process.monitor(pid)

    waiter = %{from: from, monitor_ref: monitor_ref}

    waiter_index = Map.put(state.waiter_index, monitor_ref, {:call, tool_instance_id, call_id})
    state = %{state | waiter_index: waiter_index}

    call_waiters = Map.put(instance.call_waiters, call_id, waiter)
    instance = %{instance | call_waiters: call_waiters}

    {instance, state}
  end

  defp pop_call_waiter(instance, state, _tool_instance_id, call_id) do
    {waiter, call_waiters} = Map.pop(instance.call_waiters, call_id)
    instance = %{instance | call_waiters: call_waiters}

    state =
      if waiter do
        Process.demonitor(waiter.monitor_ref, [:flush])
        waiter_index = Map.delete(state.waiter_index, waiter.monitor_ref)
        %{state | waiter_index: waiter_index}
      else
        state
      end

    {waiter, instance, state}
  end

  defp maybe_deliver_tasks(instance, state, _tool_instance_id, now_ms) do
    case instance.poll_waiter do
      nil ->
        {instance, state}

      waiter ->
        {claimed, instance} =
          claim_tasks(
            instance,
            waiter.capacity,
            waiter.runner_id,
            waiter.runner_session_id,
            now_ms
          )

        if claimed == [] do
          {instance, state}
        else
          if waiter.timer_ref do
            _ = Process.cancel_timer(waiter.timer_ref)
          end

          Process.demonitor(waiter.monitor_ref, [:flush])
          waiter_index = Map.delete(state.waiter_index, waiter.monitor_ref)
          state = %{state | waiter_index: waiter_index}

          GenServer.reply(
            waiter.from,
            {:ok,
             %{
               status: "ok",
               runner_id: waiter.runner_id,
               tasks: Enum.map(claimed, &task_payload/1)
             }}
          )

          instance = %{instance | poll_waiter: nil}
          {instance, state}
        end
    end
  end

  defp drop_poll_waiter_by_ref(state, tool_instance_id, poll_id, monitor_ref) do
    waiter_index = Map.delete(state.waiter_index, monitor_ref)
    state = %{state | waiter_index: waiter_index}

    case Map.get(state.instances, tool_instance_id) do
      nil ->
        {state, false}

      instance ->
        if instance.poll_waiter && instance.poll_waiter.id == poll_id do
          if instance.poll_waiter.timer_ref do
            _ = Process.cancel_timer(instance.poll_waiter.timer_ref)
          end

          instance = %{instance | poll_waiter: nil}
          state = put_instance(state, tool_instance_id, instance)
          {state, true}
        else
          {state, false}
        end
    end
  end

  defp drop_call_waiter_by_ref(state, tool_instance_id, call_id, monitor_ref) do
    waiter_index = Map.delete(state.waiter_index, monitor_ref)
    state = %{state | waiter_index: waiter_index}

    case Map.get(state.instances, tool_instance_id) do
      nil ->
        state

      instance ->
        pending = Enum.reject(instance.pending, &(&1.call_id == call_id))
        running = Map.delete(instance.running, call_id)
        call_waiters = Map.delete(instance.call_waiters, call_id)
        instance = %{instance | pending: pending, running: running, call_waiters: call_waiters}
        put_instance(state, tool_instance_id, instance)
    end
  end

  defp fail_running_calls(instance, state, tool_instance_id, error_text) do
    running_ids = Map.keys(instance.running)

    {instance, state} =
      Enum.reduce(running_ids, {instance, state}, fn call_id, {instance_acc, state_acc} ->
        {waiter, call_waiters} = Map.pop(instance_acc.call_waiters, call_id)
        instance_acc = %{instance_acc | call_waiters: call_waiters}

        state_acc =
          if waiter do
            Process.demonitor(waiter.monitor_ref, [:flush])
            GenServer.reply(waiter.from, {:error, error_text})
            waiter_index = Map.delete(state_acc.waiter_index, waiter.monitor_ref)
            %{state_acc | waiter_index: waiter_index}
          else
            state_acc
          end

        {instance_acc, state_acc}
      end)

    _tool_instance_id = tool_instance_id
    instance = %{instance | running: %{}}
    {instance, state}
  end

  defp fail_all_calls(instance, waiter_index, tool_instance_id, error_text) do
    {waiter_index, _} =
      Enum.reduce(instance.call_waiters, {waiter_index, 0}, fn {_call_id, waiter}, {idx_acc, n} ->
        Process.demonitor(waiter.monitor_ref, [:flush])
        GenServer.reply(waiter.from, {:error, error_text})
        {Map.delete(idx_acc, waiter.monitor_ref), n + 1}
      end)

    _tool_instance_id = tool_instance_id

    instance = %{instance | pending: [], running: %{}, call_waiters: %{}}
    {instance, waiter_index}
  end

  defp blank_to_default(value, default) when is_binary(value) and is_binary(default) do
    if String.trim(value) == "", do: default, else: value
  end
end
