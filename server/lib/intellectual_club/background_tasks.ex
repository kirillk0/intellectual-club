defmodule IntellectualClub.BackgroundTasks do
  @moduledoc """
  Ash domain and service API for durable background tool execution.

  Launch calls persist an envelope before starting work. The source tool-call
  reference makes launch idempotent across generation recovery. Adapters own
  backend-specific execution and recovery decisions, while this module owns
  authorization, lifecycle state, output cursors, and supervision.
  """

  use Ash.Domain

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.BackgroundTasks.BackgroundTaskEvent
  alias IntellectualClub.BackgroundTasks.Registry, as: AdapterRegistry
  alias IntellectualClub.BackgroundTasks.Supervisor, as: TaskSupervisor
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Outlets.Runtime, as: OutletRuntime
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query
  require Logger

  @active_statuses [:queued, :running]
  @terminal_statuses [:completed, :failed, :canceled]
  @event_page_size 500
  @event_page_max_bytes 48_000
  @maintenance_retry_limit 12

  resources do
    resource(BackgroundTask)
    resource(BackgroundTaskEvent)
  end

  @spec start_tool(ToolInstance.t(), String.t(), map(), ExecutionContext.t()) ::
          {:ok, ExecutionResult.t()} | {:error, term()}
  def start_tool(
        %ToolInstance{} = tool_instance,
        target_function,
        args,
        %ExecutionContext{} = context
      )
      when is_binary(target_function) and is_map(args) do
    adapter = adapter_for_tool(tool_instance)
    kind = kind_for_tool(tool_instance, target_function)

    start_envelope(tool_instance, target_function, args, context,
      adapter: adapter,
      kind: kind
    )
  end

  @spec start_fork(ToolInstance.t(), String.t(), ExecutionContext.t()) ::
          {:ok, ExecutionResult.t()} | {:error, term()}
  def start_fork(%ToolInstance{} = tool_instance, task, %ExecutionContext{} = context)
      when is_binary(task) do
    start_envelope(tool_instance, "fork", %{"task" => task}, context,
      adapter: "fork",
      kind: "fork"
    )
  end

  @spec snapshot(Ecto.UUID.t(), String.t() | integer() | nil, pos_integer()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def snapshot(task_id, cursor, owner_id)
      when is_binary(task_id) and is_integer(owner_id) and owner_id > 0 do
    actor = actor(owner_id)

    with {:ok, %BackgroundTask{} = task} <- fetch_owned(task_id, actor),
         {:ok, events} <- list_events(task.id, cursor, actor) do
      {task, adapter_snapshot} = reconcile_adapter_snapshot(task, cursor)
      base = snapshot_map(task, cursor, events)
      {:ok, merge_adapter_snapshot(base, adapter_snapshot)}
    end
  end

  def snapshot(_task_id, _cursor, _owner_id), do: {:error, :not_found}

  @spec cancel(Ecto.UUID.t(), pos_integer()) :: {:ok, map()} | {:error, :not_found | term()}
  def cancel(task_id, owner_id)
      when is_binary(task_id) and is_integer(owner_id) and owner_id > 0 do
    actor = actor(owner_id)

    with {:ok, %BackgroundTask{} = task} <- fetch_owned(task_id, actor) do
      if task.status in @terminal_statuses do
        snapshot(task.id, nil, owner_id)
      else
        with {:ok, requested} <- update_task(task, %{cancel_requested: true}, actor) do
          adapter_result = cancel_adapter(requested)

          case TaskSupervisor.cancel_task(task.id) do
            :ok ->
              :ok

            {:error, _reason} ->
              :ok

            :not_found ->
              maybe_finish_detached_cancel(requested, adapter_result)
          end

          snapshot(task.id, nil, owner_id)
        end
      end
    end
  end

  def cancel(_task_id, _owner_id), do: {:error, :not_found}

  @doc "Returns an owned task record for adapter integrations."
  @spec get(Ecto.UUID.t(), pos_integer()) :: {:ok, BackgroundTask.t()} | {:error, :not_found}
  def get(task_id, owner_id)
      when is_binary(task_id) and is_integer(owner_id) and owner_id > 0 do
    fetch_owned(task_id, actor(owner_id))
  end

  def get(_task_id, _owner_id), do: {:error, :not_found}

  @doc "Updates backend-specific references without bypassing task ownership policies."
  @spec update_runner_ref(BackgroundTask.t() | Ecto.UUID.t(), map()) ::
          {:ok, BackgroundTask.t()} | {:error, term()}
  def update_runner_ref(task_or_id, runner_ref) when is_map(runner_ref) do
    with {:ok, task} <- resolve_internal_task(task_or_id) do
      update_task(task, %{runner_ref: normalize_json(runner_ref)}, actor(task.owner_id))
    end
  end

  @doc "Associates a detached fork envelope with its root child chat."
  @spec set_target_chat(BackgroundTask.t() | Ecto.UUID.t(), pos_integer()) ::
          {:ok, BackgroundTask.t()} | {:error, term()}
  def set_target_chat(task_or_id, chat_id) when is_integer(chat_id) and chat_id > 0 do
    with {:ok, task} <- resolve_internal_task(task_or_id) do
      update_task(task, %{target_chat_id: chat_id}, actor(task.owner_id))
    end
  end

  @doc false
  @spec set_fork_reference(BackgroundTask.t() | Ecto.UUID.t(), map()) ::
          {:ok, BackgroundTask.t()} | {:error, term()}
  def set_fork_reference(task_or_id, reference) when is_map(reference) do
    with {:ok, task} <- resolve_internal_task(task_or_id),
         chat_id when is_integer(chat_id) and chat_id > 0 <-
           Map.get(reference, :chat_id),
         message_id when is_integer(message_id) and message_id > 0 <-
           Map.get(reference, :message_id),
         generation_message_id
         when is_integer(generation_message_id) and
                generation_message_id > 0 <-
           Map.get(reference, :generation_message_id) do
      runner_ref =
        task.runner_ref
        |> case do
          %{} = refs -> normalize_json(refs)
          _other -> %{}
        end
        |> Map.merge(%{
          "fork_chat_id" => chat_id,
          "fork_message_id" => message_id,
          "fork_generation_message_id" => generation_message_id,
          "fork_url" => to_string(Map.get(reference, :url) || "/chats/#{chat_id}")
        })

      update_task(
        task,
        %{target_chat_id: chat_id, runner_ref: runner_ref},
        actor(task.owner_id)
      )
    else
      _other -> {:error, :invalid_fork_reference}
    end
  end

  @spec active_fork_root_chat_ids(list(integer())) :: MapSet.t(integer())
  def active_fork_root_chat_ids(parent_chat_ids) when is_list(parent_chat_ids) do
    parent_chat_ids = parent_chat_ids |> Enum.filter(&is_integer/1) |> Enum.uniq()

    if parent_chat_ids == [] do
      MapSet.new()
    else
      tasks =
        BackgroundTask
        |> Ash.Query.filter(
          kind == "fork" and status in ^@active_statuses and source_chat_id in ^parent_chat_ids and
            (not is_nil(target_chat_id) or not is_nil(source_tool_call_item_id))
        )
        |> Ash.Query.select([:target_chat_id, :source_tool_call_item_id])
        |> Ash.read!(authorize?: false)

      direct_ids =
        tasks
        |> Enum.map(& &1.target_chat_id)
        |> Enum.filter(&is_integer/1)

      missing_source_ids =
        tasks
        |> Enum.filter(&is_nil(&1.target_chat_id))
        |> Enum.map(& &1.source_tool_call_item_id)
        |> Enum.filter(&is_integer/1)

      fallback_ids =
        if missing_source_ids == [] do
          []
        else
          Chat
          |> Ash.Query.filter(
            parent_tool_call_item_id in ^missing_source_ids and parent_relation_kind == :fork
          )
          |> Ash.Query.select([:id])
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.id)
        end

      MapSet.new(direct_ids ++ fallback_ids)
    end
  end

  def active_fork_root_chat_ids(_other), do: MapSet.new()

  @doc "Appends a cursor-addressable stdout or stderr chunk."
  @spec append_event(BackgroundTask.t() | Ecto.UUID.t(), :stdout | :stderr, binary()) ::
          {:ok, BackgroundTaskEvent.t()} | {:error, term()}
  def append_event(task_or_id, stream, data)
      when stream in [:stdout, :stderr] and is_binary(data) do
    with {:ok, task} <- resolve_internal_task(task_or_id) do
      safe_data = if String.valid?(data), do: data, else: String.replace_invalid(data)
      actor = actor(task.owner_id)

      BackgroundTaskEvent
      |> Ash.Changeset.for_create(
        :append,
        %{
          background_task_id: task.id,
          stream: stream,
          data: safe_data,
          byte_size: byte_size(data)
        },
        actor: actor
      )
      |> Ash.create(actor: actor)
    end
  end

  @doc false
  def fetch_internal(task_id) when is_binary(task_id) do
    case Ash.get(BackgroundTask, task_id, authorize?: false) do
      {:ok, %BackgroundTask{} = task} -> {:ok, task}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def load_tool_instance(%BackgroundTask{tool_instance_id: tool_instance_id, owner_id: owner_id})
      when is_integer(tool_instance_id) and is_integer(owner_id) do
    case Ash.get(ToolInstance, tool_instance_id, actor: actor(owner_id)) do
      {:ok, %ToolInstance{} = tool_instance} -> {:ok, tool_instance}
      _other -> {:error, :tool_instance_not_found}
    end
  end

  def load_tool_instance(_task), do: {:error, :tool_instance_not_found}

  @doc false
  @spec execution_context(BackgroundTask.t()) :: ExecutionContext.t()
  def execution_context(%BackgroundTask{} = task) do
    map = task.execution_context || %{}

    %ExecutionContext{
      owner_id: context_value(map, "owner_id", task.owner_id),
      chat_id: context_value(map, "chat_id"),
      message_id: context_value(map, "message_id"),
      assistant_message_id: context_value(map, "assistant_message_id"),
      step_id: context_value(map, "step_id"),
      provider_type: context_value(map, "provider_type"),
      available_file_external_ids: context_value(map, "available_file_external_ids", []),
      tool_call_item_id: context_value(map, "tool_call_item_id"),
      tool_call_created_at: map |> context_value("tool_call_created_at") |> parse_datetime()
    }
  end

  @doc false
  def mark_running(%BackgroundTask{} = task) do
    transition_nonterminal(task, fn current ->
      if current.status == :queued and current.cancel_requested != true do
        update_task(
          current,
          %{status: :running, started_at: current.started_at || DateTime.utc_now(), error: nil},
          actor(current.owner_id)
        )
      else
        {:error, :not_queued}
      end
    end)
  end

  @doc false
  def mark_running_detached(%BackgroundTask{} = task, refs) when is_map(refs) do
    with {:ok, current} <- fetch_internal(task.id) do
      runner_ref =
        Map.get(refs, "runner_ref")
        |> case do
          %{} = value -> value
          _other -> refs
        end

      attrs = %{runner_ref: normalize_json(runner_ref)}

      attrs =
        case Map.get(refs, "target_chat_id") do
          value when is_integer(value) and value > 0 -> Map.put(attrs, :target_chat_id, value)
          _other -> attrs
        end

      update_task(current, attrs, actor(current.owner_id))
    end
  end

  @doc false
  def mark_completed(%BackgroundTask{} = task, result) do
    transition_nonterminal(task, fn current ->
      update_task(
        current,
        %{
          status: :completed,
          result: execution_result_map(result),
          error: nil,
          finished_at: DateTime.utc_now()
        },
        actor(current.owner_id)
      )
    end)
  end

  @doc false
  def mark_failed(%BackgroundTask{} = task, code, reason, outcome \\ "unknown") do
    transition_nonterminal(task, fn current ->
      update_task(
        current,
        %{
          status: :failed,
          error: error_map(code, reason, outcome),
          finished_at: DateTime.utc_now()
        },
        actor(current.owner_id)
      )
    end)
  end

  @doc false
  def mark_canceled(%BackgroundTask{} = task) do
    transition_nonterminal(task, fn current ->
      update_task(
        current,
        %{
          status: :canceled,
          cancel_requested: true,
          finished_at: DateTime.utc_now()
        },
        actor(current.owner_id)
      )
    end)
  end

  defp transition_nonterminal(%BackgroundTask{} = task, fun) when is_function(fun, 1) do
    case Ash.transaction(BackgroundTask, fn ->
           current =
             BackgroundTask
             |> Ash.Query.filter(id == ^task.id)
             |> Ash.Query.lock(:for_update)
             |> Ash.read_one!(authorize?: false)

           if is_nil(current) do
             {:error, :not_found}
           else
             if current.status in @terminal_statuses, do: {:ok, current}, else: fun.(current)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_task(%BackgroundTask{} = task, attrs, actor) when is_map(attrs) do
    task
    |> Ash.Changeset.for_update(:update_state, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp resolve_internal_task(%BackgroundTask{} = task), do: fetch_internal(task.id)
  defp resolve_internal_task(task_id) when is_binary(task_id), do: fetch_internal(task_id)
  defp resolve_internal_task(_other), do: {:error, :not_found}

  defp required_owner_id(%ExecutionContext{owner_id: owner_id})
       when is_integer(owner_id) and owner_id > 0,
       do: {:ok, owner_id}

  defp required_owner_id(_context), do: {:error, :owner_id_required}

  defp adapter_for_tool(%ToolInstance{type: type}) do
    case type |> to_string() |> String.trim() do
      "ssh" -> "ssh"
      "outlet" -> "outlet"
      other -> other
    end
  end

  defp kind_for_tool(%ToolInstance{type: type}, function_name) do
    type = type |> to_string() |> String.trim()

    case {type, function_name} do
      {"ssh", "run_command"} -> "ssh_command"
      {"outlet", _function_name} -> "outlet_function"
      _other -> "#{type}_tool"
    end
  end

  defp serialize_execution_context(%ExecutionContext{} = context) do
    context
    |> Map.from_struct()
    |> Enum.into(%{}, fn {key, value} -> {Atom.to_string(key), normalize_json(value)} end)
  end

  defp execution_result_map(result) do
    result = ExecutionResult.normalize(result)

    %{
      "text" => result.text,
      "raw" => normalize_json(result.raw),
      "media" => normalize_json(result.media),
      "artifacts" => normalize_json(result.artifacts)
    }
  end

  defp error_map(code, %{} = reason, outcome) do
    reason = normalize_json(reason)

    %{
      "code" => to_string(Map.get(reason, "code", code)),
      "message" => to_string(Map.get(reason, "message", inspect(reason))),
      "outcome" => to_string(Map.get(reason, "outcome", outcome))
    }
  end

  defp error_map(code, reason, outcome) do
    %{
      "code" => to_string(code),
      "message" => error_message(reason),
      "outcome" => to_string(outcome)
    }
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp actor(owner_id), do: %User{id: owner_id}

  defp context_value(map, key, default \\ nil) do
    Map.get(map, key, default)
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_other), do: nil

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json(%_{} = value), do: value |> Map.from_struct() |> normalize_json()

  defp normalize_json(%{} = value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json(nested)} end)
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> normalize_json()

  defp normalize_json(value) when is_boolean(value) or is_nil(value), do: value
  defp normalize_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json(value), do: value

  defp cursor_id(nil), do: 0
  defp cursor_id(value) when is_integer(value) and value >= 0, do: value

  defp cursor_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0
    end
  end

  defp cursor_id(_other), do: 0

  defp normalize_cursor(nil), do: nil
  defp normalize_cursor(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp normalize_cursor(value) when is_binary(value), do: value
  defp normalize_cursor(_other), do: nil

  defp runner_value(task, key) do
    task.runner_ref
    |> case do
      %{} = refs -> Map.get(refs, key, "")
      _other -> ""
    end
    |> to_string()
  end

  defp datetime_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_iso(_other), do: nil

  @doc "Marks active envelopes tied to an outlet session that was replaced."
  @spec fail_outlet_session(integer(), String.t(), String.t()) :: :ok
  def fail_outlet_session(tool_instance_id, runner_id, runner_session_id)
      when is_integer(tool_instance_id) and is_binary(runner_id) and
             is_binary(runner_session_id) do
    list_active_outlet_tasks(tool_instance_id)
    |> Enum.filter(fn task ->
      runner_value(task, "runner_id") == runner_id and
        runner_value(task, "runner_session_id") == runner_session_id
    end)
    |> Enum.each(fn task ->
      _ =
        mark_failed(
          task,
          "outlet_runner_restarted",
          "Outlet runner session was replaced before completion.",
          "unknown"
        )
    end)

    :ok
  end

  def fail_outlet_session(_tool_instance_id, _runner_id, _runner_session_id), do: :ok

  @doc "Reconciles active outlet envelopes without blocking the outlet runtime GenServer."
  @spec reconcile_outlet_async(integer(), String.t(), String.t()) :: :ok
  def reconcile_outlet_async(tool_instance_id, runner_id, runner_session_id)
      when is_integer(tool_instance_id) and is_binary(runner_id) and
             is_binary(runner_session_id) do
    start_maintenance_task(fn ->
      reconcile_outlet_session(tool_instance_id, runner_id, runner_session_id)
    end)

    :ok
  end

  def reconcile_outlet_async(_tool_instance_id, _runner_id, _runner_session_id), do: :ok

  @doc false
  @spec reconcile_outlet_session(integer(), String.t(), String.t()) :: :ok
  def reconcile_outlet_session(tool_instance_id, runner_id, runner_session_id)
      when is_integer(tool_instance_id) and is_binary(runner_id) and
             is_binary(runner_session_id) do
    reconcile_outlet(tool_instance_id, runner_id, runner_session_id)
  end

  def reconcile_outlet_session(_tool_instance_id, _runner_id, _runner_session_id), do: :ok

  @doc "Loads durable file-access context for an authenticated outlet background call."
  @spec fetch_outlet_execution_context(ToolInstance.t(), Ecto.UUID.t()) ::
          {:ok, ExecutionContext.t()} | {:error, :not_found}
  def fetch_outlet_execution_context(%ToolInstance{id: tool_instance_id}, task_id)
      when is_integer(tool_instance_id) and is_binary(task_id) do
    with {:ok, %BackgroundTask{} = task} <- fetch_internal(task_id),
         true <- task.adapter == "outlet" and task.tool_instance_id == tool_instance_id do
      {:ok, execution_context(task)}
    else
      _other -> {:error, :not_found}
    end
  end

  def fetch_outlet_execution_context(_tool_instance, _task_id), do: {:error, :not_found}

  @doc "Recovers queued work and reconciles running work after backend startup."
  @spec recover() :: :ok
  def recover do
    BackgroundTask
    |> Ash.Query.filter(status in ^@active_statuses)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn task ->
      case safe_recover_if_lost(task, :startup) do
        :ok -> :ok
        {:error, _reason} -> schedule_recovery_retry(task.id)
      end
    end)

    :ok
  end

  @doc "Reaps active durable tasks whose local worker disappeared."
  @spec reap_lost_workers() :: :ok | {:error, term()}
  def reap_lost_workers do
    failures =
      BackgroundTask
      |> Ash.Query.filter(status in ^@active_statuses)
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.read!(authorize?: false)
      |> Enum.reduce([], fn task, failures ->
        case safe_recover_if_lost(task, :live) do
          :ok -> failures
          {:error, reason} -> [{task.id, reason} | failures]
        end
      end)

    case failures do
      [] -> :ok
      failures -> {:error, {:task_recovery_failed, Enum.reverse(failures)}}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec recover_async() :: :ok
  def recover_async do
    start_maintenance_task(fn -> recover_until_available(0) end)

    :ok
  end

  defp start_envelope(tool_instance, function_name, args, context, opts) do
    with :ok <- require_source_tool_call(context),
         {:ok, owner_id} <- required_owner_id(context),
         {:ok, task} <- find_or_create_task(tool_instance, function_name, args, context, opts) do
      if task.status == :queued and task.cancel_requested != true do
        start_worker_best_effort(task.id)
      end

      {:ok, launch_result(task, owner_id)}
    end
  end

  defp require_source_tool_call(%ExecutionContext{tool_call_item_id: id})
       when is_integer(id) and id > 0,
       do: :ok

  defp require_source_tool_call(_context) do
    {:error, "Background task launch requires a persisted source tool call."}
  end

  defp find_or_create_task(tool_instance, function_name, args, context, opts) do
    actor = actor(context.owner_id)
    source_tool_call_item_id = context.tool_call_item_id

    case find_by_source_tool_call(source_tool_call_item_id, actor) do
      %BackgroundTask{} = task ->
        {:ok, task}

      nil ->
        attrs = %{
          kind: Keyword.fetch!(opts, :kind),
          adapter: Keyword.fetch!(opts, :adapter),
          status: :queued,
          function_name: function_name,
          arguments: normalize_json(args),
          execution_context: serialize_execution_context(context),
          runner_ref: %{},
          tool_instance_id: tool_instance.id,
          source_chat_id: context.chat_id,
          source_message_id: context.assistant_message_id || context.message_id,
          source_step_id: context.step_id,
          source_tool_call_item_id: source_tool_call_item_id
        }

        case BackgroundTask
             |> Ash.Changeset.for_create(:create, attrs, actor: actor)
             |> Ash.create(actor: actor) do
          {:ok, task} ->
            {:ok, task}

          {:error, error} ->
            case find_by_source_tool_call(source_tool_call_item_id, actor) do
              %BackgroundTask{} = task -> {:ok, task}
              nil -> {:error, error}
            end
        end
    end
  end

  defp find_by_source_tool_call(source_tool_call_item_id, actor)
       when is_integer(source_tool_call_item_id) do
    BackgroundTask
    |> Ash.Query.filter(source_tool_call_item_id == ^source_tool_call_item_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: actor)
  end

  defp find_by_source_tool_call(_source_tool_call_item_id, _actor), do: nil

  defp launch_result(task, _owner_id) do
    status = Atom.to_string(task.status)

    %ExecutionResult{
      text: "Background task #{task.id} is #{status}.",
      raw: %{
        "background_task_id" => task.id,
        "kind" => task.kind,
        "status" => status
      },
      media: [],
      artifacts: []
    }
  end

  defp fetch_owned(task_id, actor) do
    case Ash.get(BackgroundTask, task_id, actor: actor) do
      {:ok, %BackgroundTask{} = task} -> {:ok, task}
      _other -> {:error, :not_found}
    end
  end

  defp list_events(task_id, cursor, actor) do
    cursor_id = cursor_id(cursor)

    events =
      BackgroundTaskEvent
      |> Ash.Query.filter(background_task_id == ^task_id and id > ^cursor_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(@event_page_size)
      |> Ash.read!(actor: actor)
      |> take_event_page()

    {:ok, events}
  rescue
    exception -> {:error, exception}
  end

  defp take_event_page(events) when is_list(events) do
    events
    |> Enum.reduce_while({[], 0}, fn event, {selected, bytes} ->
      event_bytes = Kernel.max(event.byte_size || byte_size(event.data || ""), 0)

      if selected != [] and bytes + event_bytes > @event_page_max_bytes do
        {:halt, {selected, bytes}}
      else
        {:cont, {[event | selected], bytes + event_bytes}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp snapshot_map(task, cursor, events) do
    next_cursor =
      case List.last(events) do
        %BackgroundTaskEvent{id: id} -> Integer.to_string(id)
        _other -> normalize_cursor(cursor) || "0"
      end

    %{
      "background_task_id" => task.id,
      "kind" => task.kind,
      "status" => Atom.to_string(task.status),
      "cancel_requested" => task.cancel_requested == true,
      "target_chat_id" => task.target_chat_id,
      "runner_ref" => task.runner_ref || %{},
      "progress" =>
        Enum.map(events, fn event ->
          %{
            "cursor" => Integer.to_string(event.id),
            "type" => Atom.to_string(event.stream),
            "text" => event.data
          }
        end),
      "next_cursor" => next_cursor,
      "result" => task.result,
      "error" => task.error,
      "created_at" => datetime_iso(task.inserted_at),
      "started_at" => datetime_iso(task.started_at),
      "finished_at" => datetime_iso(task.finished_at),
      "updated_at" => datetime_iso(task.updated_at)
    }
  end

  defp reconcile_adapter_snapshot(%BackgroundTask{status: status} = task, cursor)
       when status in @terminal_statuses do
    with {:ok, module} <- AdapterRegistry.fetch(task.adapter),
         true <- function_exported?(module, :snapshot_background, 2),
         {:ok, %{} = extra} <-
           apply(module, :snapshot_background, [task, normalize_cursor(cursor)]) do
      extra =
        extra
        |> normalize_json()
        |> adapter_snapshot_view()

      {task, extra}
    else
      _other -> {task, %{}}
    end
  rescue
    _exception -> {task, %{}}
  catch
    _kind, _reason -> {task, %{}}
  end

  defp reconcile_adapter_snapshot(task, cursor) do
    with {:ok, module} <- AdapterRegistry.fetch(task.adapter),
         true <- function_exported?(module, :snapshot_background, 2),
         {:ok, %{} = extra} <-
           apply(module, :snapshot_background, [task, normalize_cursor(cursor)]) do
      extra = normalize_json(extra)
      persist_adapter_snapshot(task, extra)
      {refreshed_task(task), adapter_snapshot_view(extra)}
    else
      _other -> {task, %{}}
    end
  rescue
    _exception -> {task, %{}}
  catch
    _kind, _reason -> {task, %{}}
  end

  defp merge_adapter_snapshot(base, extra) when is_map(base) and is_map(extra) do
    Map.merge(base, extra)
  end

  defp adapter_snapshot_view(extra) when is_map(extra) do
    Map.take(extra, [
      "progress",
      "next_cursor",
      "url",
      "status_detail",
      "outlet_error"
    ])
  end

  defp persist_adapter_snapshot(task, extra) do
    task = persist_adapter_refs(task, extra)
    status = Map.get(extra, "status") |> to_string()

    case status do
      "completed" ->
        _ = mark_completed(task, Map.get(extra, "result") || %{})

      "failed" ->
        error = Map.get(extra, "error") || %{}

        _ =
          mark_failed(
            task,
            Map.get(error, "code", "execution_failed"),
            error,
            Map.get(error, "outcome", "unknown")
          )

      "canceled" ->
        _ = mark_canceled(task)

      _other ->
        :ok
    end
  end

  defp persist_adapter_refs(task, extra) do
    task =
      case Map.get(extra, "runner_ref") do
        %{} = refs ->
          case update_runner_ref(task, refs) do
            {:ok, updated} -> updated
            _other -> task
          end

        _other ->
          task
      end

    case Map.get(extra, "target_chat_id") do
      chat_id when is_integer(chat_id) and chat_id > 0 ->
        case set_target_chat(task, chat_id) do
          {:ok, updated} -> updated
          _other -> task
        end

      _other ->
        task
    end
  end

  defp refreshed_task(task) do
    case fetch_internal(task.id) do
      {:ok, refreshed} -> refreshed
      _other -> task
    end
  end

  defp recover_task(%BackgroundTask{status: :queued, cancel_requested: true} = task, _mode) do
    _ = mark_canceled(task)
  end

  defp recover_task(%BackgroundTask{status: :running, cancel_requested: true} = task, _mode) do
    recover_cancel_requested(task)
  end

  defp recover_task(%BackgroundTask{status: :queued, adapter: "outlet"} = task, :live) do
    recover_live_outlet_queue(task)
  end

  defp recover_task(%BackgroundTask{status: :queued, adapter: "outlet"}, _mode), do: :ok

  defp recover_task(%BackgroundTask{status: :queued} = task, _mode) do
    _ = TaskSupervisor.start_task(task.id)
  end

  defp recover_task(%BackgroundTask{status: :running} = task, mode) do
    recover_running(task, mode)
  end

  defp recover_task(_task, _mode), do: :ok

  defp recover_live_outlet_queue(%BackgroundTask{} = task) do
    with {:ok, tool_instance} <- load_tool_instance(task),
         {:ok, _identity} <- OutletRuntime.runner_identity(tool_instance) do
      TaskSupervisor.start_task(task.id)
    else
      {:error, :offline} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp recover_cancel_requested(%BackgroundTask{} = task) do
    case cancel_adapter(task) do
      :ok -> mark_canceled(task)
      {:error, _reason} = error -> error
      other -> {:error, {:cancel_not_acknowledged, other}}
    end
  end

  defp recover_running(%BackgroundTask{} = task, mode) do
    with {:ok, module} <- AdapterRegistry.fetch(task.adapter),
         true <- function_exported?(module, :recover_background, 1) do
      case apply(module, :recover_background, [task]) do
        :restart ->
          with {:ok, %BackgroundTask{status: :queued, cancel_requested: false} = queued} <-
                 requeue_running_task(task) do
            _ = TaskSupervisor.start_task(queued.id)
          end

        :keep ->
          :ok

        :execution_lost ->
          if mode == :live, do: best_effort_stop_lost_execution(task)

          mark_failed(
            task,
            "execution_lost",
            "Background execution state was lost during backend restart.",
            "unknown"
          )

        {:completed, result} ->
          _ = mark_completed(task, result)

        {:failed, reason} ->
          _ = mark_failed(task, "execution_failed", reason, "unknown")

        :canceled ->
          _ = mark_canceled(task)
      end
    else
      _other ->
        _ = mark_failed(task, "unknown_adapter", task.adapter, "unknown")
    end
  rescue
    exception ->
      _ = mark_failed(task, "recovery_failed", Exception.message(exception), "unknown")
  catch
    kind, reason ->
      _ = mark_failed(task, "recovery_failed", inspect({kind, reason}), "unknown")
  end

  defp best_effort_stop_lost_execution(%BackgroundTask{} = task) do
    case cancel_adapter(task) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Background task lost execution cleanup failed task_id=#{task.id}: #{inspect(reason)}"
        )

        :ok

      _other ->
        :ok
    end
  end

  defp requeue_running_task(%BackgroundTask{} = task) do
    transition_nonterminal(task, fn current ->
      if current.status == :running and current.cancel_requested != true do
        update_task(
          current,
          %{status: :queued, started_at: nil, finished_at: nil},
          actor(current.owner_id)
        )
      else
        {:error, :not_restartable}
      end
    end)
  end

  defp reconcile_outlet(tool_instance_id, runner_id, runner_session_id) do
    list_active_outlet_tasks(tool_instance_id)
    |> Enum.each(fn task ->
      case safe_reconcile_outlet_task(task, runner_id, runner_session_id) do
        :ok ->
          :ok

        {:error, _reason} ->
          schedule_outlet_reconciliation_retry(task.id, runner_id, runner_session_id)
      end
    end)
  end

  defp reconcile_outlet_task(task, runner_id, runner_session_id) do
    bound_runner_id = runner_value(task, "runner_id")
    bound_session_id = runner_value(task, "runner_session_id")
    bound? = bound_runner_id != "" or bound_session_id != ""
    same_session? = bound_runner_id == runner_id and bound_session_id == runner_session_id

    result =
      cond do
        bound? and not same_session? ->
          mark_failed(
            task,
            "outlet_runner_restarted",
            "Outlet runner session changed before completion.",
            "unknown"
          )

        task.cancel_requested == true ->
          case cancel_adapter(task) do
            :ok -> mark_canceled(task)
            {:error, _reason} = error -> error
            other -> {:error, {:cancel_not_acknowledged, other}}
          end

        task.status == :queued ->
          TaskSupervisor.start_task(task.id)

        task.status == :running and not worker_active?(task.id) ->
          recover_running(task, :live)

        true ->
          :ok
      end

    normalize_maintenance_result(result)
  end

  defp list_active_outlet_tasks(tool_instance_id) do
    BackgroundTask
    |> Ash.Query.filter(
      adapter == "outlet" and tool_instance_id == ^tool_instance_id and
        status in ^@active_statuses
    )
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp safe_recover_task(task, mode) do
    task
    |> recover_task(mode)
    |> normalize_maintenance_result()
  rescue
    exception ->
      Logger.warning(
        "Background task recovery failed task_id=#{task.id}: #{Exception.message(exception)}"
      )

      {:error, exception}
  catch
    kind, reason ->
      Logger.warning(
        "Background task recovery stopped task_id=#{task.id}: #{inspect({kind, reason})}"
      )

      {:error, {kind, reason}}
  end

  defp safe_recover_if_lost(%BackgroundTask{} = task, mode) do
    if worker_active?(task.id) do
      :ok
    else
      with_recovery_lock(task.id, fn ->
        case fetch_internal(task.id) do
          {:ok, %BackgroundTask{status: status} = current} when status in @active_statuses ->
            if worker_active?(current.id), do: :ok, else: safe_recover_task(current, mode)

          {:ok, %BackgroundTask{}} ->
            :ok

          {:error, :not_found} ->
            :ok

          {:error, _reason} = error ->
            error
        end
      end)
    end
  rescue
    exception ->
      Logger.warning(
        "Background task live recovery failed task_id=#{task.id}: #{Exception.message(exception)}"
      )

      {:error, exception}
  catch
    kind, reason ->
      Logger.warning(
        "Background task live recovery stopped task_id=#{task.id}: #{inspect({kind, reason})}"
      )

      {:error, {kind, reason}}
  end

  defp safe_reconcile_outlet_task(task, runner_id, runner_session_id) do
    reconcile_outlet_task(task, runner_id, runner_session_id)
  rescue
    exception ->
      Logger.warning(
        "Outlet background reconciliation failed task_id=#{task.id}: " <>
          Exception.message(exception)
      )

      {:error, exception}
  catch
    kind, reason ->
      Logger.warning(
        "Outlet background reconciliation stopped task_id=#{task.id}: " <>
          inspect({kind, reason})
      )

      {:error, {kind, reason}}
  end

  defp schedule_recovery_retry(task_id) do
    start_maintenance_task(fn -> retry_recovery_task(task_id, 1) end)
  end

  defp retry_recovery_task(_task_id, attempt) when attempt > @maintenance_retry_limit, do: :ok

  defp retry_recovery_task(task_id, attempt) do
    Process.sleep(maintenance_retry_delay(attempt))

    case fetch_internal(task_id) do
      {:ok, %BackgroundTask{status: status} = task} when status in @active_statuses ->
        case safe_recover_if_lost(task, :startup) do
          :ok -> :ok
          {:error, _reason} -> retry_recovery_task(task_id, attempt + 1)
        end

      {:error, :not_found} ->
        :ok

      {:error, _reason} ->
        retry_recovery_task(task_id, attempt + 1)

      _other ->
        :ok
    end
  end

  defp schedule_outlet_reconciliation_retry(task_id, runner_id, runner_session_id) do
    start_maintenance_task(fn ->
      retry_outlet_reconciliation(task_id, runner_id, runner_session_id, 1)
    end)
  end

  defp retry_outlet_reconciliation(_task_id, _runner_id, _runner_session_id, attempt)
       when attempt > @maintenance_retry_limit,
       do: :ok

  defp retry_outlet_reconciliation(task_id, runner_id, runner_session_id, attempt) do
    Process.sleep(maintenance_retry_delay(attempt))

    case fetch_internal(task_id) do
      {:ok, %BackgroundTask{adapter: "outlet", status: status} = task}
      when status in @active_statuses ->
        case safe_reconcile_outlet_task(task, runner_id, runner_session_id) do
          :ok ->
            :ok

          {:error, _reason} ->
            retry_outlet_reconciliation(
              task_id,
              runner_id,
              runner_session_id,
              attempt + 1
            )
        end

      {:error, :not_found} ->
        :ok

      {:error, _reason} ->
        retry_outlet_reconciliation(task_id, runner_id, runner_session_id, attempt + 1)

      _other ->
        :ok
    end
  end

  defp recover_until_available(attempt) do
    recover()
  rescue
    exception ->
      Logger.warning("Background task recovery failed: #{Exception.message(exception)}")
      Process.sleep(maintenance_retry_delay(attempt + 1))
      recover_until_available(attempt + 1)
  catch
    kind, reason ->
      Logger.warning("Background task recovery stopped: #{inspect({kind, reason})}")
      Process.sleep(maintenance_retry_delay(attempt + 1))
      recover_until_available(attempt + 1)
  end

  defp start_maintenance_task(fun) when is_function(fun, 0) do
    supervisor = IntellectualClub.BackgroundTasks.ExecutionSupervisor

    if Process.whereis(supervisor) do
      Task.Supervisor.start_child(supervisor, fun)
    else
      Task.start(fun)
    end
  end

  defp maintenance_retry_delay(attempt) when is_integer(attempt) do
    Kernel.min(
      5_000,
      trunc(:math.pow(2, Kernel.min(Kernel.max(attempt, 1), 8))) * 25
    )
  end

  defp normalize_maintenance_result(:ok), do: :ok
  defp normalize_maintenance_result({:ok, _value}), do: :ok
  defp normalize_maintenance_result({:error, _reason} = error), do: error
  defp normalize_maintenance_result(other), do: {:error, {:unexpected_result, other}}

  defp start_worker_best_effort(task_id) when is_binary(task_id) do
    case TaskSupervisor.start_task(task_id) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Background task worker could not start task_id=#{task_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Background task worker could not start task_id=#{task_id}: " <>
          Exception.message(exception)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Background task worker could not start task_id=#{task_id}: #{inspect({kind, reason})}"
      )

      :ok
  end

  defp with_recovery_lock(task_id, fun) when is_binary(task_id) and is_function(fun, 0) do
    registry = IntellectualClub.BackgroundTasks.ProcessRegistry
    lock_key = {:background_task_recovery, task_id}

    case Registry.register(registry, lock_key, nil) do
      {:ok, _owner} ->
        try do
          fun.()
        after
          Registry.unregister(registry, lock_key)
        end

      {:error, {:already_registered, _pid}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec worker_active?(Ecto.UUID.t()) :: boolean()
  def worker_active?(task_id) when is_binary(task_id) do
    Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task_id) != []
  end

  def worker_active?(_task_id), do: false

  defp cancel_adapter(task) do
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

  defp maybe_finish_detached_cancel(%BackgroundTask{status: :queued} = task, _adapter_result) do
    mark_canceled(task)
  end

  defp maybe_finish_detached_cancel(task, :ok), do: mark_canceled(task)
  defp maybe_finish_detached_cancel(_task, {:error, _reason}), do: :ok
  defp maybe_finish_detached_cancel(task, _other), do: mark_canceled(task)
end
