defmodule IntellectualClub.Generation.QueueDispatcher do
  @moduledoc """
  Supervised durable queue dispatcher.

  Casts are only latency hints. Periodic database reconciliation and generation
  recovery keep queue delivery independent from browser and process lifetimes.
  """

  use GenServer

  require Logger

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Notifications.Dispatcher, as: NotificationsDispatcher

  @default_reconcile_interval_ms 2_000
  @start_retry_delay_ms 25
  @max_start_retries 160

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Hints that a chat queue may now be dispatchable."
  @spec kick(integer()) :: :ok
  def kick(chat_id) when is_integer(chat_id) do
    if Application.get_env(:intellectual_club, :queue_dispatcher_reconcile, true) and
         Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:kick, chat_id})
    end

    :ok
  end

  def kick(_chat_id), do: :ok

  @doc "Starts a transactionally prepared queued generation after its commit."
  @spec start_prepared(map()) :: :ok
  def start_prepared(%{message_id: message_id} = context) when is_integer(message_id) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:start_prepared, context})
    else
      _ = start_prepared_without_dispatcher(context)
    end

    :ok
  catch
    :exit, _reason ->
      _ = start_prepared_without_dispatcher(context)
      :ok
  end

  def start_prepared(_context), do: :ok

  @doc "Persists a generation boundary and synchronously prepares the next turn when possible."
  @spec generation_finished(integer(), :done | :error | :canceled) :: term()
  def generation_finished(message_id, status)
      when is_integer(message_id) and status in [:done, :error, :canceled] do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:generation_finished, message_id, status}, 30_000)
    else
      settle_without_dispatcher(message_id, status)
    end
  catch
    :exit, _reason -> settle_without_dispatcher(message_id, status)
  end

  @doc "Transfers a terminal handoff backlog to its child continuation chat."
  @spec handoff(integer(), integer(), integer() | nil) :: term()
  def handoff(source_message_id, child_chat_id, child_generation_message_id \\ nil)
      when is_integer(source_message_id) and is_integer(child_chat_id) do
    if Process.whereis(__MODULE__) do
      GenServer.call(
        __MODULE__,
        {:handoff, source_message_id, child_chat_id, child_generation_message_id},
        30_000
      )
    else
      transfer_without_dispatcher(
        source_message_id,
        child_chat_id,
        child_generation_message_id
      )
    end
  catch
    :exit, _reason ->
      transfer_without_dispatcher(
        source_message_id,
        child_chat_id,
        child_generation_message_id
      )
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(
        opts,
        :reconcile_interval_ms,
        Application.get_env(
          :intellectual_club,
          :queue_reconcile_interval_ms,
          @default_reconcile_interval_ms
        )
      )

    reconcile? =
      Keyword.get(
        opts,
        :reconcile?,
        Application.get_env(:intellectual_club, :queue_dispatcher_reconcile, true)
      )

    {:ok, %{interval_ms: max(interval_ms, 100), reconcile?: reconcile?}, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    state =
      if state.reconcile? do
        NotificationsDispatcher.recover_generation_events()

        if Application.get_env(
             :intellectual_club,
             :recover_orphaned_generations_on_startup,
             true
           ) do
          _ = GenerationSupervisor.recover_orphaned_generations_async()
        end

        reconcile(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:kick, chat_id}, state) do
    _ = dispatch_chat(chat_id)
    {:noreply, state}
  end

  def handle_cast({:start_prepared, context}, state) do
    schedule_prepared_start(context, 0)
    {:noreply, state}
  end

  @impl true
  def handle_call({:generation_finished, message_id, status}, _from, state) do
    result =
      case QueueCoordinator.settle_generation(message_id, status) do
        {:ok, %{chat_id: chat_id}} when status == :done ->
          BackgroundTasks.cancel_for_source_message_async(message_id)

          chat_id
          |> dispatch_chat(boundary_message_id: message_id)
          |> normalize_boundary_dispatch()

        {:ok, payload} ->
          BackgroundTasks.cancel_for_source_message_async(message_id)
          {:blocked, payload}

        {:error, reason} = error ->
          Logger.warning(
            "Failed to settle queued generation message_id=#{message_id} " <>
              "status=#{status} reason=#{inspect(reason)}"
          )

          error
      end

    {:reply, result, state}
  end

  def handle_call(
        {:handoff, source_message_id, child_chat_id, child_generation_message_id},
        _from,
        state
      ) do
    result =
      case QueueCoordinator.transfer_to_handoff(
             source_message_id,
             child_chat_id,
             child_generation_message_id
           ) do
        {:ok, %{transferred_count: count} = payload} when count > 0 ->
          dispatch = handoff_dispatch(payload, child_chat_id, &dispatch_chat/1)

          {:transferred, Map.put(payload, :dispatch, dispatch)}

        {:ok, payload} ->
          {:empty, payload}

        {:error, _reason} = error ->
          error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {:noreply, reconcile(state)}
  end

  def handle_info({:start_prepared, context, attempt}, state) do
    case GenerationSupervisor.start_prepared_context(context) do
      {:ok, _context} ->
        :ok

      {:error, :already_running} ->
        :ok

      {:error, reason} when attempt < @max_start_retries ->
        Logger.debug(
          "Queued generation worker start deferred message_id=#{context.message_id} " <>
            "attempt=#{attempt + 1} reason=#{inspect(reason)}"
        )

        schedule_prepared_start(context, attempt + 1)

      other ->
        Logger.warning(
          "Failed to start durable queued generation message_id=#{context.message_id} " <>
            "result=#{inspect(other)}"
        )

        _ = GenerationSupervisor.recover_orphaned_generations_async()
    end

    {:noreply, state}
  end

  defp reconcile(state) do
    NotificationsDispatcher.recover_generation_events()

    QueueCoordinator.ready_chat_ids()
    |> Enum.each(&dispatch_chat/1)

    Process.send_after(self(), :reconcile, state.interval_ms)
    state
  rescue
    exception ->
      Logger.warning("Queued message reconciliation failed: #{Exception.message(exception)}")
      Process.send_after(self(), :reconcile, state.interval_ms)
      state
  end

  defp dispatch_chat(chat_id, opts \\ []) do
    case QueueCoordinator.prepare_next(chat_id, opts) do
      {:ok, context} ->
        schedule_prepared_start(context, 0)
        {:advanced, context.message_id}

      :empty ->
        :empty

      :active ->
        :active

      {:blocked, reason} ->
        {:blocked, reason}

      {:error, reason} = error ->
        Logger.warning(
          "Failed to dispatch queued chat turn chat_id=#{chat_id} reason=#{inspect(reason)}"
        )

        error
    end
  end

  defp schedule_prepared_start(context, attempt) do
    Process.send_after(self(), {:start_prepared, context, attempt}, @start_retry_delay_ms)
    :ok
  end

  defp settle_without_dispatcher(message_id, status) do
    case QueueCoordinator.settle_generation(message_id, status) do
      {:ok, %{chat_id: chat_id}} when status == :done ->
        BackgroundTasks.cancel_for_source_message_async(message_id)

        case QueueCoordinator.prepare_next(chat_id, boundary_message_id: message_id) do
          {:ok, context} -> start_prepared_without_dispatcher(context)
          :active -> {:advanced, :active}
          other -> other
        end

      {:ok, payload} ->
        BackgroundTasks.cancel_for_source_message_async(message_id)
        {:blocked, payload}

      {:error, _reason} = error ->
        error
    end
  end

  defp transfer_without_dispatcher(
         source_message_id,
         child_chat_id,
         child_generation_message_id
       ) do
    case QueueCoordinator.transfer_to_handoff(
           source_message_id,
           child_chat_id,
           child_generation_message_id
         ) do
      {:ok, %{transferred_count: count} = payload} when count > 0 ->
        dispatch =
          handoff_dispatch(payload, child_chat_id, fn chat_id ->
            case QueueCoordinator.prepare_next(chat_id) do
              {:ok, context} -> start_prepared_without_dispatcher(context)
              other -> other
            end
          end)

        {:transferred, Map.put(payload, :dispatch, dispatch)}

      {:ok, payload} ->
        {:empty, payload}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_boundary_dispatch(:active), do: {:advanced, :active}
  defp normalize_boundary_dispatch(result), do: result

  defp handoff_dispatch(%{child_generation_status: :generating}, _child_chat_id, _dispatch),
    do: :active

  defp handoff_dispatch(%{child_generation_status: status}, _child_chat_id, _dispatch)
       when status in [:error, :canceled],
       do: {:blocked, status}

  defp handoff_dispatch(_payload, child_chat_id, dispatch), do: dispatch.(child_chat_id)

  defp start_prepared_without_dispatcher(context) do
    result =
      try do
        GenerationSupervisor.start_prepared_context(context)
      rescue
        exception -> {:error, {:exception, Exception.message(exception)}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    case result do
      {:ok, _context} ->
        :ok

      {:error, :already_running} ->
        :ok

      other ->
        Logger.warning(
          "Failed to start durable queued generation without dispatcher " <>
            "message_id=#{context.message_id} result=#{inspect(other)}"
        )

        _ = GenerationSupervisor.recover_orphaned_generations_async()
    end

    {:advanced, context.message_id}
  end
end
