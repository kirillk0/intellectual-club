defmodule IntellectualClub.Generation.Supervisor do
  @moduledoc """
  Starts and manages per-message generation workers.
  """

  use DynamicSupervisor

  require Logger

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Worker

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
    :ok = cancel_for_chat(chat_id)

    context = Context.build!(chat_id, opts)
    start_worker(context)
  end

  def start_prepared_generation(chat_id, message_id, step_id, raw_request, opts \\ [])
      when is_integer(chat_id) and is_integer(message_id) and is_integer(step_id) and
             is_list(opts) do
    actor = Keyword.get(opts, :actor)

    :ok = Context.authorize_chat!(chat_id, actor)
    :ok = cancel_for_chat(chat_id, orphan_exception_message_ids: [message_id])

    context = Context.build_prepared!(chat_id, message_id, step_id, raw_request, opts)
    start_worker(context)
  end

  def retry_last_step(message_id, opts \\ []) when is_integer(message_id) and is_list(opts) do
    retry_opts = Keyword.put_new(opts, :allowed_statuses, @manual_retry_statuses)

    with {:ok, context} <- Context.prepare_retry(message_id, retry_opts),
         :ok <- cancel_for_chat(context.chat_id),
         step_sequence when is_integer(step_sequence) and step_sequence > 0 <-
           Map.get(context, :initial_step_sequence),
         steering_specs when is_list(steering_specs) <-
           Persistence.steering_specs_for_step!(context.step_id),
         {:ok, request_payload, steering_specs} <-
           prepare_retry_steering(context, steering_specs),
         step_id when is_integer(step_id) <-
           Persistence.replace_steps_for_retry!(
             context.message_id,
             step_sequence,
             request_payload,
             steering_specs
           ) do
      context = %{context | step_id: step_id, request_payload: request_payload}
      start_worker(context)
    else
      nil ->
        {:error, :no_steps_to_retry}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :retry_failed}
    end
  end

  def retry_from_step(message_id, step_id, opts \\ [])
      when is_integer(message_id) and is_integer(step_id) and is_list(opts) do
    retry_opts =
      opts
      |> Keyword.put(:step_id, step_id)
      |> Keyword.put_new(:allowed_statuses, @retry_from_step_statuses)

    with {:ok, context} <- Context.prepare_retry(message_id, retry_opts),
         :ok <- cancel_for_chat(context.chat_id),
         step_sequence when is_integer(step_sequence) and step_sequence > 0 <-
           Map.get(context, :initial_step_sequence),
         steering_specs when is_list(steering_specs) <-
           Persistence.steering_specs_for_step!(context.step_id),
         {:ok, request_payload, steering_specs} <-
           prepare_retry_steering(context, steering_specs),
         step_id when is_integer(step_id) <-
           Persistence.replace_steps_for_retry!(
             context.message_id,
             step_sequence,
             request_payload,
             steering_specs
           ) do
      context = %{context | step_id: step_id, request_payload: request_payload}
      start_worker(context)
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
    resume_opts = Keyword.put_new(opts, :allowed_statuses, @resume_retry_statuses)

    with {:ok, context} <- Context.prepare_retry(message_id, resume_opts),
         step_sequence when is_integer(step_sequence) and step_sequence > 0 <-
           Map.get(context, :initial_step_sequence) do
      case orphaned_resume_strategy(context) do
        :restart_steered_step ->
          start_worker(%{context | initial_resume_mode: :steered_waiting_provider})

        :resume_waiting_tools ->
          start_worker(%{context | initial_resume_mode: :waiting_tools})

        :resume_completed_tool_step ->
          start_worker(%{context | initial_resume_mode: :completed_tool_step})

        :finalize_completed_step ->
          :ok = Persistence.persist_completed_from_step!(context.message_id, context.step_id)
          {:ok, context}

        :restart_step ->
          step_id =
            Persistence.replace_steps_for_retry!(
              context.message_id,
              step_sequence,
              context.request_payload || %{}
            )

          context = %{context | step_id: step_id}
          start_worker(context)
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
    Task.start(fn ->
      try do
        recover_orphaned_generations()
      rescue
        exception ->
          Logger.warning(
            "Failed to run orphaned generation recovery on startup: #{Exception.message(exception)}"
          )
      catch
        :exit, reason ->
          Logger.warning("Orphaned generation recovery exited on startup: #{inspect(reason)}")
      end
    end)

    :ok
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
            :ok = Persistence.cancel_orphaned_generating_message!(message_id)

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

  def cancel_generation(message_id, opts \\ []) when is_list(opts) do
    result =
      case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
        [{pid, _}] ->
          Worker.cancel(pid)
          _ = await_worker_stopped(pid)
          :ok

        [] ->
          :not_found
      end

    :ok = cancel_descendant_generations_for_message(message_id, opts)
    result
  end

  def steer_generation(message_id, text) when is_integer(message_id) and is_binary(text) do
    case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
      [{pid, _}] ->
        try do
          Worker.steer(pid, text)
        catch
          :exit, _reason -> {:error, :generation_not_active}
        end

      [] ->
        {:error, :generation_not_active}
    end
  end

  def cancel_for_chat(chat_id), do: cancel_for_chat(chat_id, [])

  defp cancel_for_chat(chat_id, opts) do
    active_message_ids = cancel_active_workers_for_chat(chat_id)
    orphan_exception_message_ids = Keyword.get(opts, :orphan_exception_message_ids, [])
    :ok = cancel_descendant_generations_for_chat(chat_id)

    :ok =
      Persistence.cancel_orphaned_generating_messages!(chat_id,
        except_message_ids: Enum.uniq(active_message_ids ++ orphan_exception_message_ids)
      )

    :ok
  end

  defp cancel_active_workers_for_chat(chat_id) when is_integer(chat_id) do
    entries = Registry.lookup(IntellectualClub.Generation.Registry, {:chat, chat_id})

    Enum.each(entries, fn {pid, _metadata} -> Worker.cancel(pid) end)
    Enum.each(entries, fn {pid, _metadata} -> await_worker_stopped(pid) end)

    entries
    |> Enum.map(fn {_pid, metadata} -> registry_message_id(metadata) end)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp cancel_active_workers_for_chat(_chat_id), do: []

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
    |> Enum.each(fn descendant_chat_id ->
      active_message_ids = cancel_active_workers_for_chat(descendant_chat_id)

      :ok =
        Persistence.cancel_orphaned_generating_messages!(descendant_chat_id,
          except_message_ids: active_message_ids
        )
    end)

    :ok
  end

  defp cancel_descendant_generations_for_chat(_chat_id, _opts), do: :ok

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
          background_roots = active_background_fork_root_chat_ids(parent_ids)
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

  defp active_background_fork_root_chat_ids(parent_chat_ids) when is_list(parent_chat_ids) do
    if Code.ensure_loaded?(IntellectualClub.BackgroundTasks) and
         function_exported?(
           IntellectualClub.BackgroundTasks,
           :active_fork_root_chat_ids,
           1
         ) do
      case apply(IntellectualClub.BackgroundTasks, :active_fork_root_chat_ids, [parent_chat_ids]) do
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
        "Failed to load active background fork roots: #{Exception.message(exception)}"
      )

      MapSet.new()
  end

  defp registry_message_id(%{message_id: id}) when is_integer(id), do: id
  defp registry_message_id(_metadata), do: nil

  defp await_worker_stopped(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @cancel_wait_timeout_ms ->
          Process.demonitor(ref, [:flush])
          :timeout
      end
    else
      :ok
    end
  end

  defp await_worker_stopped(_pid), do: :ok

  def get_generation_state(message_id) do
    case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
      [{pid, _}] ->
        try do
          {:ok, Worker.get_current_state(pid)}
        catch
          :exit, _reason -> :not_found
        end

      [] ->
        :not_found
    end
  end

  def poll_generation(message_id, cursor \\ %{}, opts \\ []) when is_integer(message_id) do
    case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
      [{pid, _}] ->
        try do
          {:ok, Worker.poll(pid, cursor, opts)}
        catch
          :exit, _reason -> :not_found
        end

      [] ->
        :not_found
    end
  end

  defp start_worker(context) when is_map(context) do
    spec = %{
      id: {Worker, context.message_id},
      start: {Worker, :start_link, [%{context: context}]},
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
