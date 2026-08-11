defmodule IntellectualClub.BackgroundTasks.Worker do
  @moduledoc false

  use GenServer

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.BackgroundTasks.Registry, as: AdapterRegistry
  alias IntellectualClub.Tools.ExecutionResult

  require Logger

  @max_claim_retry_ms 5_000
  @max_persist_retry_ms 5_000
  @max_wait_retry_ms 5_000

  defstruct [
    :task_id,
    :task,
    :execution_task,
    :generation_monitor_ref,
    :generation_pid,
    :generation_message_id,
    :pending_result,
    :reply_to,
    claim_attempts: 0,
    persist_attempts: 0,
    wait_attempts: 0,
    waiting?: false
  ]

  def start_link(opts) when is_list(opts) do
    task_id = Keyword.fetch!(opts, :task_id)

    GenServer.start_link(__MODULE__, task_id,
      name: {:via, Registry, {IntellectualClub.BackgroundTasks.ProcessRegistry, task_id}}
    )
  end

  @impl true
  def init(task_id) do
    {:ok, %__MODULE__{task_id: task_id}, {:continue, :execute}}
  end

  @impl true
  def handle_continue(:execute, state) do
    attempt_claim(state)
  end

  @impl true
  def handle_call(:cancel, from, %{pending_result: pending_result} = state)
      when not is_nil(pending_result) do
    if successful_execution_result?(pending_result) do
      _ = shutdown_execution_task(state.execution_task)

      persist_or_retry(
        %{state | execution_task: nil, reply_to: from},
        pending_result
      )
    else
      handle_cancel_without_successful_result(from, state)
    end
  end

  def handle_call(:cancel, from, state) do
    handle_cancel_without_successful_result(from, state)
  end

  defp handle_cancel_without_successful_result(from, state) do
    with {:ok, %BackgroundTask{} = task} <- BackgroundTasks.fetch_internal(state.task_id) do
      case completed_wait_result(state, task) do
        {:ok, result} ->
          state = clear_generation_monitor(state)
          _ = shutdown_execution_task(state.execution_task)
          persist_or_retry(%{state | execution_task: nil, reply_to: from}, result)

        :not_completed ->
          case cancel_adapter(task) do
            :ok ->
              shutdown_result = shutdown_execution_task(state.execution_task)
              finish_cancel_after_shutdown(state, task, from, shutdown_result)

            {:error, reason} ->
              finish_cancel_adapter_error(state, task, from, reason, state.pending_result)

            _other ->
              shutdown_result = shutdown_execution_task(state.execution_task)
              finish_cancel_after_shutdown(state, task, from, shutdown_result)
          end
      end
    else
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:retry_claim, state) do
    attempt_claim(state)
  end

  def handle_info(
        {ref, {:waiting, _runtime_reference}},
        %{execution_task: %Task{ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])

    state
    |> Map.put(:execution_task, nil)
    |> Map.put(:waiting?, true)
    |> reconcile_wait()
  end

  def handle_info({ref, result}, %{execution_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    persist_or_retry(%{state | execution_task: nil}, result)
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{execution_task: %Task{ref: ref}} = state
      ) do
    if reason not in [:normal, :shutdown] do
      persist_or_retry(
        %{state | execution_task: nil},
        {:worker_crashed, Exception.format_exit(reason)}
      )
    else
      {:stop, :normal, %{state | execution_task: nil}}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{generation_monitor_ref: ref, generation_pid: pid} = state
      ) do
    state
    |> clear_generation_monitor(flush?: false)
    |> reconcile_wait()
  end

  def handle_info(:reconcile_wait, %{waiting?: true, generation_monitor_ref: nil} = state) do
    reconcile_wait(state)
  end

  def handle_info({:cancel_wait_runtime, result}, state) do
    cancel_wait_runtime_before_failure(state, result)
  end

  def handle_info(:persist_result, %{pending_result: result} = state) when not is_nil(result) do
    persist_or_retry(state, result)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp attempt_claim(state) do
    case BackgroundTasks.fetch_internal(state.task_id) do
      {:ok, %BackgroundTask{status: :queued, cancel_requested: true} = task} ->
        persist_or_retry(%{state | task: task}, :canceled)

      {:ok, %BackgroundTask{status: :queued} = task} ->
        case BackgroundTasks.mark_running(task) do
          {:ok, %BackgroundTask{status: :running} = running} ->
            start_execution(%{state | task: running, claim_attempts: 0}, running)

          {:ok, %BackgroundTask{} = current} ->
            finish_claim_race(%{state | task: current}, current)

          {:error, :not_queued} ->
            finish_claim_race(%{state | task: task}, task)

          {:error, reason} ->
            retry_claim(%{state | task: task}, reason)
        end

      {:ok, %BackgroundTask{}} ->
        {:stop, :normal, state}

      {:error, :not_found} ->
        {:stop, :normal, state}

      {:error, reason} ->
        retry_claim(state, reason)
    end
  rescue
    exception -> retry_claim(state, {:exception, Exception.message(exception)})
  catch
    kind, reason -> retry_claim(state, {kind, reason})
  end

  defp start_execution(state, task) do
    execution_task =
      Task.Supervisor.async_nolink(
        IntellectualClub.BackgroundTasks.ExecutionSupervisor,
        fn -> execute_adapter(task) end
      )

    {:noreply, %{state | execution_task: execution_task}}
  rescue
    exception ->
      Logger.warning(
        "Background task execution worker could not start task_id=#{task.id}: " <>
          Exception.message(exception)
      )

      {:stop, :normal, state}
  catch
    kind, reason ->
      Logger.warning(
        "Background task execution worker could not start task_id=#{task.id}: " <>
          inspect({kind, reason})
      )

      {:stop, :normal, state}
  end

  defp retry_claim(state, reason) do
    attempts = state.claim_attempts + 1
    delay_ms = retry_delay(attempts, @max_claim_retry_ms)

    Logger.warning(
      "Background task claim failed task_id=#{state.task_id} " <>
        "attempt=#{attempts}: #{inspect(reason)}"
    )

    Process.send_after(self(), :retry_claim, delay_ms)
    {:noreply, %{state | claim_attempts: attempts}}
  end

  defp execute_adapter(%BackgroundTask{} = task) do
    with {:ok, module} <- AdapterRegistry.fetch(task.adapter),
         true <- function_exported?(module, :execute_background, 5),
         {:ok, tool_instance} <- BackgroundTasks.load_tool_instance(task),
         execution_context = BackgroundTasks.execution_context(task) do
      apply(module, :execute_background, [
        task,
        tool_instance,
        task.function_name,
        task.arguments || %{},
        execution_context
      ])
    else
      false -> {:error, {:adapter_callback_missing, task.adapter}}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp cancel_adapter(%BackgroundTask{} = task) do
    with {:ok, module} <- AdapterRegistry.fetch(task.adapter),
         true <- function_exported?(module, :cancel_background, 1) do
      module.cancel_background(task)
    else
      _other -> :ok
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp reconcile_adapter(%BackgroundTask{} = task) do
    with {:ok, module} <- AdapterRegistry.fetch(task.adapter),
         true <- function_exported?(module, :reconcile_background, 1) do
      apply(module, :reconcile_background, [task])
    else
      false -> {:error, {:adapter_callback_missing, :reconcile_background, task.adapter}}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp reconcile_adapter_read_only(%BackgroundTask{} = task) do
    with {:ok, module} <- AdapterRegistry.fetch(task.adapter),
         true <- function_exported?(module, :reconcile_background_read_only, 1) do
      apply(module, :reconcile_background_read_only, [task])
    else
      false ->
        {:retry, {:adapter_callback_missing, :reconcile_background_read_only, task.adapter}}

      {:error, _reason} = error ->
        error
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp reconcile_wait(state) do
    case BackgroundTasks.fetch_internal(state.task_id) do
      {:ok, %BackgroundTask{status: status}} when status in [:completed, :failed, :canceled] ->
        {:stop, :normal, clear_generation_monitor(state)}

      {:ok, %BackgroundTask{cancel_requested: true} = task} ->
        reconcile_requested_cancel(state, task)

      {:ok, %BackgroundTask{} = task} ->
        handle_reconcile_result(state, task, reconcile_adapter(task))

      {:error, :not_found} ->
        {:stop, :normal, clear_generation_monitor(state)}

      {:error, reason} ->
        retry_wait(state, reason)
    end
  rescue
    exception -> retry_wait(state, {:exception, Exception.message(exception)})
  catch
    kind, reason -> retry_wait(state, {kind, reason})
  end

  defp handle_reconcile_result(state, _task, result) do
    cond do
      successful_execution_result?(result) ->
        state
        |> clear_generation_monitor()
        |> Map.put(:waiting?, false)
        |> persist_or_retry(result)

      true ->
        do_handle_reconcile_result(state, result)
    end
  end

  defp do_handle_reconcile_result(
         state,
         {:waiting, %{generation_message_id: message_id, pid: pid}}
       )
       when is_integer(message_id) and is_pid(pid) do
    monitor_generation(state, message_id, pid)
  end

  defp do_handle_reconcile_result(state, {:retry, reason}) do
    retry_wait(clear_generation_monitor(state), reason)
  end

  defp do_handle_reconcile_result(state, result)
       when result == :canceled or (is_tuple(result) and elem(result, 0) == :failed) do
    state
    |> clear_generation_monitor()
    |> Map.put(:waiting?, false)
    |> persist_or_retry(result)
  end

  defp do_handle_reconcile_result(state, {:error, _reason} = error) do
    state
    |> clear_generation_monitor()
    |> cancel_wait_runtime_before_failure(error)
  end

  defp do_handle_reconcile_result(state, result) do
    state
    |> clear_generation_monitor()
    |> cancel_wait_runtime_before_failure({:error, {:invalid_reconcile_result, result}})
  end

  defp monitor_generation(state, message_id, pid) do
    state = clear_generation_monitor(state)
    monitor_ref = Process.monitor(pid)

    state = %{
      state
      | generation_monitor_ref: monitor_ref,
        generation_pid: pid,
        generation_message_id: message_id,
        wait_attempts: 0,
        waiting?: true
    }

    case BackgroundTasks.fetch_internal(state.task_id) do
      {:ok, %BackgroundTask{cancel_requested: true} = task} ->
        state
        |> clear_generation_monitor()
        |> reconcile_requested_cancel(task)

      {:ok, %BackgroundTask{} = task} ->
        case reconcile_adapter(task) do
          {:waiting, %{generation_message_id: ^message_id, pid: ^pid}} ->
            {:noreply, state}

          result ->
            state
            |> clear_generation_monitor()
            |> handle_reconcile_result(task, result)
        end

      {:error, :not_found} ->
        {:stop, :normal, clear_generation_monitor(state)}

      {:error, reason} ->
        state
        |> clear_generation_monitor()
        |> retry_wait(reason)
    end
  end

  defp retry_wait(state, reason) do
    attempts = state.wait_attempts + 1
    delay_ms = retry_delay(attempts, @max_wait_retry_ms)

    Logger.debug(
      "Background task generation wait deferred task_id=#{state.task_id} " <>
        "attempt=#{attempts}: #{inspect(reason)}"
    )

    Process.send_after(self(), :reconcile_wait, delay_ms)
    {:noreply, %{state | wait_attempts: attempts, waiting?: true}}
  end

  defp reconcile_requested_cancel(state, task) do
    case cancel_adapter(task) do
      {:error, reason} ->
        retry_wait(clear_generation_monitor(state), {:cancel_failed, reason})

      _other ->
        handle_requested_cancel_reconcile_result(
          clear_generation_monitor(state),
          reconcile_adapter_read_only(task)
        )
    end
  end

  defp handle_requested_cancel_reconcile_result(state, result)
       when result == :canceled or
              (is_tuple(result) and elem(result, 0) in [:completed, :failed]) do
    state
    |> Map.put(:waiting?, false)
    |> persist_or_retry(result)
  end

  defp handle_requested_cancel_reconcile_result(state, {:error, reason}) do
    retry_wait(state, {:read_only_reconcile_failed, reason})
  end

  defp handle_requested_cancel_reconcile_result(state, {:retry, reason}) do
    retry_wait(state, reason)
  end

  defp handle_requested_cancel_reconcile_result(state, {:waiting, reference}) do
    retry_wait(state, {:cancel_not_terminal, reference})
  end

  defp handle_requested_cancel_reconcile_result(state, result) do
    retry_wait(state, {:invalid_read_only_reconcile_result, result})
  end

  defp cancel_wait_runtime_before_failure(state, result) do
    case BackgroundTasks.fetch_internal(state.task_id) do
      {:ok, %BackgroundTask{status: status}} when status in [:completed, :failed, :canceled] ->
        {:stop, :normal, clear_generation_monitor(state)}

      {:ok, %BackgroundTask{} = task} ->
        case cancel_adapter(task) do
          {:error, reason} ->
            retry_wait_runtime_cancel(clear_generation_monitor(state), result, reason)

          _other ->
            state
            |> clear_generation_monitor()
            |> Map.put(:waiting?, false)
            |> persist_or_retry(result)
        end

      {:error, :not_found} ->
        {:stop, :normal, clear_generation_monitor(state)}

      {:error, reason} ->
        retry_wait_runtime_cancel(clear_generation_monitor(state), result, reason)
    end
  rescue
    exception ->
      retry_wait_runtime_cancel(
        clear_generation_monitor(state),
        result,
        {:exception, Exception.message(exception)}
      )
  catch
    kind, reason ->
      retry_wait_runtime_cancel(clear_generation_monitor(state), result, {kind, reason})
  end

  defp retry_wait_runtime_cancel(state, result, reason) do
    attempts = state.wait_attempts + 1
    delay_ms = retry_delay(attempts, @max_wait_retry_ms)

    Logger.warning(
      "Background task wait failure cleanup deferred task_id=#{state.task_id} " <>
        "attempt=#{attempts}: #{inspect(reason)}"
    )

    Process.send_after(self(), {:cancel_wait_runtime, result}, delay_ms)
    {:noreply, %{state | wait_attempts: attempts, waiting?: true}}
  end

  defp completed_wait_result(_state, %BackgroundTask{} = task) do
    result = reconcile_adapter_read_only(task)
    if successful_execution_result?(result), do: {:ok, result}, else: :not_completed
  end

  defp clear_generation_monitor(state, opts \\ []) do
    case state.generation_monitor_ref do
      ref when is_reference(ref) ->
        if Keyword.get(opts, :flush?, true), do: Process.demonitor(ref, [:flush])

      _other ->
        :ok
    end

    %{
      state
      | generation_monitor_ref: nil,
        generation_pid: nil,
        generation_message_id: nil
    }
  end

  defp persist_execution_result(task, {:ok, %ExecutionResult{} = result}) do
    BackgroundTasks.mark_completed(task, result)
  end

  defp persist_execution_result(task, {:ok, %{} = result}) do
    BackgroundTasks.mark_completed(task, result)
  end

  defp persist_execution_result(task, {:completed, result}) do
    BackgroundTasks.mark_completed(task, result)
  end

  defp persist_execution_result(task, {:running, refs}) when is_map(refs) do
    BackgroundTasks.mark_running_detached(task, refs)
  end

  defp persist_execution_result(task, {:failed, reason}) do
    BackgroundTasks.mark_failed(task, "execution_failed", reason, "failed")
  end

  defp persist_execution_result(task, :canceled) do
    BackgroundTasks.mark_canceled(task)
  end

  defp persist_execution_result(task, {:error, reason}) do
    BackgroundTasks.mark_failed(task, "execution_failed", reason, "failed")
  end

  defp persist_execution_result(task, {:worker_crashed, reason}) do
    BackgroundTasks.mark_failed(task, "worker_crashed", reason, "unknown")
  end

  defp persist_execution_result(task, other) do
    BackgroundTasks.mark_failed(task, "invalid_adapter_result", inspect(other), "unknown")
  end

  defp persist_or_retry(state, result) do
    {persistence_result, state} = persist_with_current_task(state, result)

    case persistence_result do
      {:ok, %BackgroundTask{}} ->
        finish_persistence(state)

      :ok ->
        finish_persistence(state)

      {:error, :not_found} ->
        finish_persistence(state)

      {:error, reason} ->
        retry_persistence(state, result, reason)

      other ->
        retry_persistence(state, result, {:unexpected_result, other})
    end
  end

  defp persist_with_current_task(state, result) do
    case BackgroundTasks.fetch_internal(state.task_id) do
      {:ok, %BackgroundTask{} = task} ->
        effective_result = effective_persistence_result(task, result)

        persistence_result =
          try do
            persist_execution_result(task, effective_result)
          rescue
            exception -> {:error, {:exception, Exception.message(exception)}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        {persistence_result, %{state | task: task}}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  rescue
    exception -> {{:error, {:exception, Exception.message(exception)}}, state}
  catch
    kind, reason -> {{:error, {kind, reason}}, state}
  end

  defp effective_persistence_result(
         %BackgroundTask{cancel_requested: true},
         result
       ) do
    if successful_execution_result?(result), do: result, else: :canceled
  end

  defp effective_persistence_result(_task, result), do: result

  defp successful_execution_result?({:ok, %ExecutionResult{}}), do: true
  defp successful_execution_result?({:ok, %{} = _result}), do: true
  defp successful_execution_result?({:completed, _result}), do: true
  defp successful_execution_result?(_result), do: false

  defp retry_persistence(state, result, reason) do
    state = clear_generation_monitor(state)
    attempts = state.persist_attempts + 1
    delay_ms = retry_delay(attempts, @max_persist_retry_ms)

    Logger.warning(
      "Background task result persistence failed task_id=#{state.task_id} " <>
        "attempt=#{attempts}: #{inspect(reason)}"
    )

    Process.send_after(self(), :persist_result, delay_ms)

    {:noreply,
     %{
       state
       | pending_result: result,
         persist_attempts: attempts,
         execution_task: nil,
         waiting?: false
     }}
  end

  defp finish_persistence(state) do
    state = clear_generation_monitor(state)

    if not is_nil(state.reply_to) do
      GenServer.reply(state.reply_to, :ok)
    end

    {:stop, :normal,
     %{
       state
       | pending_result: nil,
         reply_to: nil,
         persist_attempts: 0,
         execution_task: nil,
         waiting?: false
     }}
  end

  defp retry_delay(attempts, maximum_ms) do
    min(maximum_ms, trunc(:math.pow(2, min(attempts, 8))) * 25)
  end

  defp shutdown_execution_task(nil), do: :not_running

  defp shutdown_execution_task(%Task{} = task) do
    case Task.shutdown(task, 1_000) do
      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        :not_running

      result ->
        result
    end
  end

  defp finish_claim_race(state, %BackgroundTask{} = task) do
    case BackgroundTasks.fetch_internal(task.id) do
      {:ok, %BackgroundTask{status: :queued, cancel_requested: true} = current} ->
        persist_or_retry(%{state | task: current}, :canceled)

      {:ok, %BackgroundTask{status: :running, cancel_requested: true} = current} ->
        persist_or_retry(%{state | task: current}, :canceled)

      _other ->
        {:stop, :normal, state}
    end
  end

  defp finish_cancel_after_shutdown(state, fallback_task, from, shutdown_result) do
    task =
      case BackgroundTasks.fetch_internal(fallback_task.id) do
        {:ok, %BackgroundTask{} = current} -> current
        _other -> fallback_task
      end

    result = cancellation_persistence_result(state, shutdown_result)

    case cancel_adapter(task) do
      {:error, reason} ->
        finish_cancel_adapter_error(state, task, from, reason, result)

      _other ->
        persist_or_retry(
          %{state | task: task, execution_task: nil, reply_to: from},
          result
        )
    end
  end

  defp cancellation_persistence_result(
         %__MODULE__{pending_result: pending_result},
         _shutdown_result
       )
       when not is_nil(pending_result) do
    if successful_execution_result?(pending_result), do: pending_result, else: :canceled
  end

  defp cancellation_persistence_result(_state, {:ok, result}) do
    if successful_execution_result?(result), do: result, else: :canceled
  end

  defp cancellation_persistence_result(_state, _shutdown_result), do: :canceled

  defp finish_cancel_adapter_error(state, task, from, reason, result) do
    if successful_execution_result?(result) do
      persist_or_retry(
        %{state | task: task, execution_task: nil, reply_to: from},
        result
      )
    else
      {:stop, :normal, {:error, reason}, %{state | task: task}}
    end
  end
end
