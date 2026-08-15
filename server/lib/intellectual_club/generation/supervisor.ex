defmodule IntellectualClub.Generation.Supervisor do
  @moduledoc """
  Starts and manages per-message generation workers.
  """

  use DynamicSupervisor

  require Logger

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Generation.Recovery
  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.Notifications.Dispatcher, as: NotificationsDispatcher

  require Ash.Query

  @manual_retry_statuses [:error, :canceled]
  @retry_from_step_statuses [:done, :error, :canceled]
  @resume_retry_statuses [:generating]
  @cancel_wait_timeout_ms 5_000

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_generation(chat_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    :ok = Context.authorize_chat!(chat_id, actor)

    with {:ok, context} <- QueueCoordinator.prepare_direct_generation(chat_id, opts) do
      start_prepared_context(context)
    end
  end

  @doc "Starts a generation whose canonical assistant and initial step already exist."
  def start_prepared_context(%{message_id: message_id} = context)
      when is_integer(message_id) do
    with_generation_lease(message_id, &start_worker(context, &1))
  end

  def start_prepared_context(_context), do: {:error, :invalid_context}

  def start_prepared_generation(chat_id, message_id, step_id, _raw_request, opts \\ [])
      when is_integer(chat_id) and is_integer(message_id) and is_integer(step_id) and
             is_list(opts) do
    actor = Keyword.get(opts, :actor)

    :ok = Context.authorize_chat!(chat_id, actor)

    with_generation_lease(message_id, fn lease ->
      with :ok <- cancel_for_chat(chat_id, orphan_exception_message_ids: [message_id]),
           {:ok, canonical_step} <- canonical_prepared_step(chat_id, message_id, actor) do
        context =
          Context.build_prepared!(
            chat_id,
            message_id,
            canonical_step.id,
            canonical_step.raw_request || %{},
            opts
          )

        start_worker(context, lease)
      end
    end)
  end

  def retry_last_step(message_id, opts \\ []) when is_integer(message_id) and is_list(opts) do
    retry_opts = Keyword.put_new(opts, :allowed_statuses, @manual_retry_statuses)

    with_generation_reservation(
      message_id,
      &retry_with_reservation(message_id, retry_opts, &1)
    )
  end

  def retry_from_step(message_id, step_id, opts \\ [])
      when is_integer(message_id) and is_integer(step_id) and is_list(opts) do
    retry_opts =
      opts
      |> Keyword.put(:step_id, step_id)
      |> Keyword.put_new(:allowed_statuses, @retry_from_step_statuses)

    with_generation_reservation(
      message_id,
      &retry_with_reservation(message_id, retry_opts, &1)
    )
  end

  defp retry_with_reservation(message_id, retry_opts, lease) do
    allowed_statuses = Keyword.fetch!(retry_opts, :allowed_statuses)

    with {:ok, context} <- Context.prepare_retry(message_id, retry_opts),
         :ok <- cancel_for_chat(context.chat_id, orphan_exception_message_ids: [message_id]),
         step_sequence when is_integer(step_sequence) and step_sequence > 0 <-
           Map.get(context, :initial_step_sequence),
         steering_specs when is_list(steering_specs) <-
           Persistence.steering_specs_for_step!(context.step_id),
         {:ok, request_payload, steering_specs} <-
           prepare_retry_steering(context, steering_specs),
         {:ok, {lease, step_id}} <-
           claim_retry_and_replace_steps(
             lease,
             context.chat_id,
             allowed_statuses,
             context.message_id,
             step_sequence,
             request_payload,
             steering_specs
           ) do
      context = %{context | step_id: step_id, request_payload: request_payload}
      start_worker(context, lease)
    else
      nil ->
        {:error, :no_steps_to_retry}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :retry_failed}
    end
  end

  def resume_orphaned_message(message_id, opts \\ [])
      when is_integer(message_id) and is_list(opts) do
    with_generation_lease(message_id, &do_resume_orphaned_message(message_id, opts, &1))
  end

  defp do_resume_orphaned_message(message_id, opts, lease) do
    resume_opts = Keyword.put_new(opts, :allowed_statuses, @resume_retry_statuses)

    with {:ok, context} <- Context.prepare_retry(message_id, resume_opts),
         step_sequence when is_integer(step_sequence) and step_sequence > 0 <-
           Map.get(context, :initial_step_sequence) do
      case orphaned_resume_strategy(context) do
        :restart_steered_step ->
          start_worker(%{context | initial_resume_mode: :steered_waiting_provider}, lease)

        :resume_waiting_tools ->
          start_worker(%{context | initial_resume_mode: :waiting_tools}, lease)

        :resume_completed_tool_step ->
          start_worker(%{context | initial_resume_mode: :completed_tool_step}, lease)

        :finalize_completed_step ->
          start_worker(%{context | initial_resume_mode: :finalize_completed_step}, lease)

        :restart_step ->
          with {:ok, step_id} <-
                 replace_steps_for_retry_with_fence(
                   lease,
                   context.message_id,
                   step_sequence,
                   context.request_payload || %{},
                   []
                 ) do
            context = %{context | step_id: step_id}
            start_worker(context, lease)
          end
      end
    else
      nil ->
        {:error, :no_steps_to_retry}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :retry_failed}
    end
  end

  defp waiting_tools_status?(status), do: status == :waiting_tools

  defp completed_step_status?(status), do: status == :done

  defp orphaned_resume_strategy(context) when is_map(context) do
    cond do
      waiting_tools_status?(context.initial_step_status) and is_integer(context.step_id) ->
        :resume_waiting_tools

      context.initial_step_status == :waiting_provider and
        is_integer(context.step_id) and steered_waiting_provider_step?(context.step_id) ->
        :restart_steered_step

      completed_step_status?(context.initial_step_status) and is_integer(context.step_id) ->
        completed_step_resume_strategy(context.step_id)

      true ->
        :restart_step
    end
  end

  defp steered_waiting_provider_step?(step_id) when is_integer(step_id) do
    case Persistence.step_steering_state!(step_id) do
      %{before_response_count: count} when count > 0 -> true
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp completed_step_resume_strategy(step_id) when is_integer(step_id) do
    case Persistence.step_tool_resume_state!(step_id) do
      %{tool_call_count: 0} ->
        :finalize_completed_step

      %{missing_tool_call_count: 0} ->
        :resume_completed_tool_step

      _other ->
        :resume_waiting_tools
    end
  end

  def recover_orphaned_generations_async do
    Recovery.request()
  end

  def recover_orphaned_generations do
    Persistence.list_generating_messages_for_resume!()
    |> Enum.sort_by(&Map.get(&1, :id, 0))
    |> Enum.each(fn row ->
      message_id = Map.get(row, :id)
      owner_id = Map.get(row, :owner_id)

      if is_integer(message_id) and is_integer(owner_id) and owner_id > 0 do
        actor = %User{id: owner_id}

        case resume_orphaned_message(message_id, actor: actor) do
          {:ok, _context} ->
            Logger.info("Recovered orphaned generation message_id=#{message_id}")

          {:error, :already_running} ->
            :ok

          {:error, :no_steps_to_retry} ->
            _ =
              QueueCoordinator.cancel_generation(message_id,
                error_detail: "Orphaned generation (worker not found)"
              )

            NotificationsDispatcher.notify_generation_finished(message_id, :canceled)

            Logger.info(
              "Canceled orphaned generation without retryable steps message_id=#{message_id}"
            )

          {:error, reason} ->
            Logger.warning(
              "Failed to recover orphaned generation message_id=#{message_id}: #{inspect(reason)}"
            )
        end
      end
    end)

    :ok
  end

  def cancel_generation(message_id, opts \\ [])

  def cancel_generation(message_id, opts)
      when is_integer(message_id) and is_list(opts) do
    case durable_cancel_and_signal(message_id) do
      {result, worker_pid}
      when result in [:ok, :not_found] and (is_nil(worker_pid) or is_pid(worker_pid)) ->
        if is_pid(worker_pid), do: await_worker_stopped(worker_pid)

        case cancel_descendant_generations_for_message(message_id, opts) do
          :ok -> result
          {:error, _reason} = error -> error
        end

      {{:error, _reason} = error, worker_pid}
      when is_nil(worker_pid) or is_pid(worker_pid) ->
        if is_pid(worker_pid), do: await_worker_stopped(worker_pid)
        error

      {:error, _reason} = error ->
        error
    end
  end

  def cancel_generation(_message_id, _opts), do: :not_found

  @doc false
  def with_generation_start_lock(message_id, fun)
      when is_integer(message_id) and message_id > 0 and is_function(fun, 0) do
    lock_id = {{__MODULE__, :generation_start, message_id}, self()}
    nodes = Enum.uniq([node() | Node.list()])

    :global.trans(lock_id, fun, nodes)
  end

  defp with_generation_lease(message_id, fun)
       when is_integer(message_id) and message_id > 0 and is_function(fun, 1) do
    with_generation_start_lock(message_id, fn ->
      if generation_worker_active?(message_id) do
        {:error, :already_running}
      else
        case Lease.acquire(message_id) do
          {:ok, lease} ->
            try do
              fun.(lease)
            after
              Lease.release(lease)
            end

          {:error, _reason} = error ->
            error
        end
      end
    end)
  end

  defp with_generation_reservation(message_id, fun)
       when is_integer(message_id) and message_id > 0 and is_function(fun, 1) do
    with_generation_start_lock(message_id, fn ->
      if generation_worker_active?(message_id) do
        {:error, :already_running}
      else
        case Lease.reserve(message_id) do
          {:ok, lease} ->
            try do
              fun.(lease)
            after
              Lease.release(lease)
            end

          {:error, _reason} = error ->
            error
        end
      end
    end)
  end

  @doc false
  @spec generation_worker_pid(integer()) :: pid() | nil
  def generation_worker_pid(message_id) when is_integer(message_id) do
    case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
      [{pid, _metadata}] when is_pid(pid) ->
        pid

      [] ->
        case :global.whereis_name(Worker.global_name(message_id)) do
          pid when is_pid(pid) -> pid
          :undefined -> nil
        end
    end
  end

  @doc false
  @spec active_generation_candidates([integer()], [integer()]) :: %{
          chat_generations: [map()],
          message_generations: [map()]
        }
  def active_generation_candidates(chat_ids, message_ids)
      when is_list(chat_ids) and is_list(message_ids) do
    chat_generations =
      chat_ids
      |> normalize_generation_ids()
      |> Enum.flat_map(fn chat_id ->
        case Registry.lookup(IntellectualClub.Generation.Registry, {:chat, chat_id}) do
          [
            {pid,
             %{
               chat_id: ^chat_id,
               message_id: message_id,
               owner_id: owner_id
             }}
          ]
          when is_pid(pid) and is_integer(message_id) and is_integer(owner_id) ->
            [%{chat_id: chat_id, message_id: message_id, owner_id: owner_id}]

          _other ->
            []
        end
      end)

    message_generations =
      message_ids
      |> normalize_generation_ids()
      |> Enum.flat_map(fn message_id ->
        case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
          [{pid, %{chat_id: chat_id, owner_id: owner_id}}]
          when is_pid(pid) and is_integer(chat_id) and is_integer(owner_id) ->
            [%{chat_id: chat_id, message_id: message_id, owner_id: owner_id}]

          _other ->
            []
        end
      end)

    %{
      chat_generations: chat_generations,
      message_generations: message_generations
    }
  end

  def active_generation_candidates(_chat_ids, _message_ids) do
    %{chat_generations: [], message_generations: []}
  end

  defp canonical_prepared_step(chat_id, message_id, actor) do
    case Ash.get(ChatMessage, message_id, actor: actor) do
      {:ok,
       %ChatMessage{
         chat_id: ^chat_id,
         role: :assistant,
         status: :generating
       }} ->
        ChatMessageStep
        |> Ash.Query.filter(chat_message_id == ^message_id)
        |> Ash.Query.select([:id, :chat_message_id, :sequence, :status, :raw_request])
        |> Ash.Query.sort(sequence: :desc, id: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one(actor: actor)
        |> case do
          {:ok, %ChatMessageStep{} = step} -> {:ok, step}
          {:ok, nil} -> {:error, :no_steps_to_retry}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %ChatMessage{chat_id: ^chat_id, role: :assistant}} ->
        {:error, :invalid_status}

      {:ok, _message} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp normalize_generation_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
  end

  defp generation_worker_active?(message_id) when is_integer(message_id) do
    is_pid(generation_worker_pid(message_id))
  end

  defp generating_message?(message_id) when is_integer(message_id) do
    generation_message_status(message_id) == :generating
  end

  defp generation_message_status(message_id) when is_integer(message_id) do
    case read_generation_message_status(message_id) do
      {:ok, status} -> status
      _other -> nil
    end
  end

  defp durable_cancel_and_signal(message_id) when is_integer(message_id) do
    with_generation_start_lock(message_id, fn ->
      worker_pid = generation_worker_pid(message_id)

      _worker_result = cancel_active_worker(worker_pid, message_id)
      fallback_result = persist_cancel_fallback(message_id)
      result = cancellation_result(message_id, fallback_result)

      {result, worker_pid}
    end)
  end

  defp cancellation_result(message_id, fallback_result) when is_integer(message_id) do
    case read_generation_message_status(message_id) do
      {:ok, :canceled} ->
        finish_canceled_generation(message_id)
        :ok

      {:ok, :generating} ->
        {:error, {:cancellation_not_persisted, fallback_result}}

      {:ok, _terminal_status} ->
        :not_found

      :not_found ->
        :not_found

      {:error, reason} ->
        {:error, {:cancellation_status_unavailable, reason}}
    end
  end

  defp persist_cancel_fallback(message_id) when is_integer(message_id) do
    QueueCoordinator.cancel_generation(message_id, error_detail: nil)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp read_generation_message_status(message_id) when is_integer(message_id) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id)
    |> Ash.Query.select([:id, :status])
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ChatMessage{status: status}} -> {:ok, status}
      {:ok, nil} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_canceled_generation(message_id) when is_integer(message_id) do
    NotificationsDispatcher.notify_generation_finished(message_id, :canceled)
    :ok
  end

  defp cancel_active_worker(nil, _message_id), do: {:error, :worker_not_found}

  defp cancel_active_worker(worker_pid, message_id) when is_pid(worker_pid) do
    case Worker.cancel_and_wait(worker_pid, @cancel_wait_timeout_ms) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "Generation worker cancellation persistence failed; using durable fallback " <>
            "message_id=#{message_id} reason=#{inspect(reason)}"
        )

        error
    end
  catch
    :exit, reason ->
      Logger.warning(
        "Generation worker cancellation did not complete; using durable fallback " <>
          "message_id=#{message_id} reason=#{inspect(reason)}"
      )

      {:error, reason}
  end

  def steer_generation(message_id, text) when is_integer(message_id) and is_binary(text) do
    case generation_worker_pid(message_id) do
      pid when is_pid(pid) ->
        try do
          Worker.steer(pid, text)
        catch
          :exit, _reason -> {:error, :generation_not_active}
        end

      nil ->
        {:error, :generation_not_active}
    end
  end

  def queue_changed(message_id) when is_integer(message_id) do
    case generation_worker_pid(message_id) do
      pid when is_pid(pid) ->
        Worker.queue_changed(pid)
        :ok

      nil ->
        _ = recover_orphaned_generations_async()
        :ok
    end
  end

  def queue_changed(_message_id), do: :ok

  def cancel_for_chat(chat_id), do: cancel_for_chat(chat_id, [])

  defp cancel_for_chat(chat_id, opts) do
    orphan_exception_message_ids = Keyword.get(opts, :orphan_exception_message_ids, [])

    with {:ok, active_message_ids} <-
           cancel_active_workers_for_chat(chat_id,
             except_message_ids: orphan_exception_message_ids
           ),
         :ok <- cancel_descendant_generations_for_chat(chat_id) do
      cancel_orphaned_generating_messages_for_chat(
        chat_id,
        Enum.uniq(active_message_ids ++ orphan_exception_message_ids)
      )
    end
  end

  defp cancel_active_workers_for_chat(chat_id, opts \\ [])

  defp cancel_active_workers_for_chat(chat_id, opts)
       when is_integer(chat_id) and is_list(opts) do
    message_ids = active_generation_message_ids_for_chat(chat_id)

    except_message_ids =
      opts
      |> Keyword.get(:except_message_ids, [])
      |> MapSet.new()

    results =
      message_ids
      |> Enum.reject(&MapSet.member?(except_message_ids, &1))
      |> Enum.map(fn message_id -> {message_id, durable_cancel_and_signal(message_id)} end)

    Enum.each(results, fn
      {_message_id, {_result, worker_pid}} when is_pid(worker_pid) ->
        await_worker_stopped(worker_pid)

      _other ->
        :ok
    end)

    case cancellation_failure(results) do
      nil -> {:ok, Enum.filter(message_ids, &generating_message?/1)}
      {message_id, reason} -> {:error, {:generation_cancel_failed, message_id, reason}}
    end
  end

  defp cancel_active_workers_for_chat(_chat_id, _opts), do: {:ok, []}

  defp cancellation_failure(results) when is_list(results) do
    Enum.find_value(results, fn
      {message_id, {{:error, reason}, _worker_pid}} -> {message_id, reason}
      {message_id, {:error, reason}} -> {message_id, reason}
      {_message_id, {result, _worker_pid}} when result in [:ok, :not_found] -> nil
      {message_id, other} -> {message_id, {:unexpected_cancel_result, other}}
    end)
  end

  defp cancel_descendant_generations_for_message(message_id, opts)
       when is_integer(message_id) and is_list(opts) do
    case message_chat_id(message_id) do
      id when is_integer(id) -> cancel_descendant_generations_for_chat(id, opts)
      _other -> :ok
    end
  end

  defp cancel_descendant_generations_for_message(_message_id, _opts), do: :ok

  defp cancel_descendant_generations_for_chat(chat_id, opts \\ [])

  defp cancel_descendant_generations_for_chat(chat_id, opts)
       when is_integer(chat_id) and is_list(opts) do
    chat_id
    |> subagent_descendant_chat_ids(opts)
    |> Enum.reduce_while(:ok, fn descendant_chat_id, :ok ->
      case cancel_active_workers_for_chat(descendant_chat_id) do
        {:ok, active_message_ids} ->
          result =
            cancel_orphaned_generating_messages_for_chat(
              descendant_chat_id,
              active_message_ids
            )

          {:cont, result}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp cancel_descendant_generations_for_chat(_chat_id, _opts), do: :ok

  defp cancel_orphaned_generating_messages_for_chat(chat_id, except_message_ids)
       when is_integer(chat_id) and is_list(except_message_ids) do
    except_message_ids = MapSet.new(except_message_ids)

    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id and status == :generating)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&MapSet.member?(except_message_ids, &1.id))
    |> Enum.reduce_while(:ok, fn message, :ok ->
      case QueueCoordinator.cancel_generation(message.id,
             error_detail: "Orphaned generation (worker not found)"
           ) do
        :canceled ->
          finish_canceled_generation(message.id)
          {:cont, :ok}

        result when result in [:not_generating, :not_found] ->
          {:cont, :ok}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp message_chat_id(message_id) when is_integer(message_id) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id)
    |> Ash.Query.select([:id, :chat_id])
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %ChatMessage{chat_id: chat_id} when is_integer(chat_id) -> chat_id
      _other -> nil
    end
  end

  defp subagent_descendant_chat_ids(chat_id, opts) when is_integer(chat_id) and is_list(opts) do
    include_background_tasks? = Keyword.get(opts, :include_background_tasks?, false)

    do_subagent_descendant_chat_ids(
      [chat_id],
      MapSet.new(),
      [],
      include_background_tasks?
    )
  end

  defp do_subagent_descendant_chat_ids([], _visited, acc, _include_background_tasks?),
    do: Enum.reverse(acc)

  defp do_subagent_descendant_chat_ids(
         parent_ids,
         visited,
         acc,
         include_background_tasks?
       ) do
    parent_ids =
      parent_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    if parent_ids == [] do
      Enum.reverse(acc)
    else
      child_ids =
        Chat
        |> Ash.Query.filter(parent_chat_id in ^parent_ids and subagent == true)
        |> Ash.Query.select([:id])
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
        |> Enum.filter(&is_integer/1)
        |> Enum.reject(&MapSet.member?(visited, &1))
        |> Enum.uniq()

      child_ids =
        if include_background_tasks? do
          child_ids
        else
          background_roots = active_background_subagent_root_chat_ids(parent_ids)
          Enum.reject(child_ids, &MapSet.member?(background_roots, &1))
        end

      visited = Enum.reduce(parent_ids, visited, &MapSet.put(&2, &1))

      do_subagent_descendant_chat_ids(
        child_ids,
        visited,
        child_ids ++ acc,
        include_background_tasks?
      )
    end
  end

  defp active_background_subagent_root_chat_ids(parent_chat_ids) when is_list(parent_chat_ids) do
    if Code.ensure_loaded?(IntellectualClub.BackgroundTasks) and
         function_exported?(
           IntellectualClub.BackgroundTasks,
           :active_subagent_root_chat_ids,
           1
         ) do
      case apply(IntellectualClub.BackgroundTasks, :active_subagent_root_chat_ids, [
             parent_chat_ids
           ]) do
        %MapSet{} = ids -> ids
        ids when is_list(ids) -> MapSet.new(ids)
        _other -> MapSet.new()
      end
    else
      MapSet.new()
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to load active background subagent roots: #{Exception.message(exception)}"
      )

      MapSet.new()
  end

  defp registry_message_id(%{message_id: id}) when is_integer(id), do: id
  defp registry_message_id(_metadata), do: nil

  defp active_generation_message_ids_for_chat(chat_id) when is_integer(chat_id) do
    local_message_ids =
      IntellectualClub.Generation.Registry
      |> Registry.lookup({:chat, chat_id})
      |> Enum.map(fn {_pid, metadata} -> registry_message_id(metadata) end)
      |> Enum.filter(&is_integer/1)

    global_message_ids =
      ChatMessage
      |> Ash.Query.filter(
        chat_id == ^chat_id and
          (status == :generating or not is_nil(generation_fence_token))
      )
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.flat_map(fn message ->
        if is_pid(generation_worker_pid(message.id)), do: [message.id], else: []
      end)

    Enum.uniq(local_message_ids ++ global_message_ids)
  end

  defp await_worker_stopped(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @cancel_wait_timeout_ms ->
        Process.demonitor(ref, [:flush])
        :timeout
    end
  end

  def get_generation_state(message_id) do
    case generation_worker_pid(message_id) do
      pid when is_pid(pid) ->
        try do
          {:ok, Worker.get_current_state(pid)}
        catch
          :exit, _reason -> :not_found
        end

      nil ->
        :not_found
    end
  end

  def poll_generation(message_id, cursor \\ %{}, opts \\ []) when is_integer(message_id) do
    case generation_worker_pid(message_id) do
      pid when is_pid(pid) ->
        try do
          {:ok, Worker.poll(pid, cursor, opts)}
        catch
          :exit, _reason -> :not_found
        end

      nil ->
        :not_found
    end
  end

  defp start_worker(context, %Lease{} = lease) when is_map(context) do
    spec = %{
      id: {Worker, context.message_id},
      start: {Worker, :start_link, [%{context: context, lease: lease, lease_owner: self()}]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} ->
        {:ok, context}

      {:error, {:already_started, _pid}} ->
        {:error, :already_running}

      {:error, {:already_running, _pid}} ->
        {:error, :already_running}

      other ->
        other
    end
  end

  defp replace_steps_for_retry_with_fence(
         %Lease{} = lease,
         message_id,
         step_sequence,
         request_payload,
         steering_specs
       )
       when is_integer(message_id) and is_integer(step_sequence) and is_map(request_payload) and
              is_list(steering_specs) do
    case Lease.with_fence(lease, fn ->
           Persistence.replace_steps_for_retry!(
             message_id,
             step_sequence,
             request_payload,
             steering_specs
           )
         end) do
      {:ok, step_id} when is_integer(step_id) -> {:ok, step_id}
      {:error, _reason} = error -> error
      _other -> {:error, :retry_failed}
    end
  end

  defp claim_retry_and_replace_steps(
         %Lease{} = lease,
         chat_id,
         allowed_statuses,
         message_id,
         step_sequence,
         request_payload,
         steering_specs
       )
       when is_integer(chat_id) and is_list(allowed_statuses) and is_integer(message_id) and
              is_integer(step_sequence) and is_map(request_payload) and
              is_list(steering_specs) do
    case Lease.claim_and_run_with_chat(lease, chat_id, allowed_statuses, fn ->
           Persistence.replace_steps_for_retry!(
             message_id,
             step_sequence,
             request_payload,
             steering_specs
           )
         end) do
      {:ok, {%Lease{} = fenced, step_id}} when is_integer(step_id) ->
        {:ok, {fenced, step_id}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :retry_failed}
    end
  end

  defp prepare_retry_steering(context, steering_specs)
       when is_map(context) and is_list(steering_specs) do
    request_payload = Map.get(context, :request_payload) || %{}

    trailing =
      Enum.filter(steering_specs, fn spec ->
        Map.get(spec, :placement) == :after_response
      end)

    if trailing == [] do
      {:ok, request_payload, steering_specs}
    else
      adapter =
        Map.get(context, :adapter_module) ||
          IntellectualClub.Llm.Providers.Common.Registry.fetch_or_missing(
            Map.get(context, :provider_type)
          )

      injected = adapter.inject_steering(request_payload, trailing, context)

      with {:ok, raw_request} <- steering_raw_request(injected) do
        restored_specs =
          Enum.map(steering_specs, fn spec ->
            case Map.get(spec, :placement) do
              :after_response ->
                spec
                |> Map.new()
                |> Map.put(:placement, :before_response)

              _other ->
                spec
            end
          end)

        {:ok, raw_request, restored_specs}
      end
    end
  rescue
    exception -> {:error, {:steering_retry_failed, exception}}
  catch
    kind, reason -> {:error, {:steering_retry_failed, {kind, reason}}}
  end

  defp steering_raw_request(%{raw_request: %{} = raw_request}), do: {:ok, raw_request}
  defp steering_raw_request({:ok, value}), do: steering_raw_request(value)
  defp steering_raw_request(other), do: {:error, {:invalid_steering_request, other}}
end
