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

  defstruct [
    :task_id,
    :task,
    :execution_task,
    :pending_result,
    :reply_to,
    claim_attempts: 0,
    persist_attempts: 0
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
    else
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:retry_claim, state) do
    attempt_claim(state)
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
    attempts = state.persist_attempts + 1
    delay_ms = retry_delay(attempts, @max_persist_retry_ms)

    Logger.warning(
      "Background task result persistence failed task_id=#{state.task_id} " <>
        "attempt=#{attempts}: #{inspect(reason)}"
    )

    Process.send_after(self(), :persist_result, delay_ms)

    {:noreply, %{state | pending_result: result, persist_attempts: attempts, execution_task: nil}}
  end

  defp finish_persistence(state) do
    if not is_nil(state.reply_to) do
      GenServer.reply(state.reply_to, :ok)
    end

    {:stop, :normal,
     %{state | pending_result: nil, reply_to: nil, persist_attempts: 0, execution_task: nil}}
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
