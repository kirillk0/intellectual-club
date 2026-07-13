defmodule IntellectualClub.Tools.Drivers.Outlet do
  @moduledoc """
  Outlet runner driver (HTTP long polling).

  The runner connects to the server and executes tool calls on behalf of a
  `ToolInstance` of type `outlet`. The server-side transport is implemented in
  `IntellectualClub.Outlets.Runtime` and is intentionally in-memory (non-durable).
  """

  @behaviour IntellectualClub.Tools.Driver
  @behaviour IntellectualClub.BackgroundTasks.Adapter

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  @background_progress_page_max_bytes 48_000

  @impl true
  def type, do: "outlet"

  @impl true
  def title, do: "Outlet"

  @impl true
  def description, do: "Execute tools via an outlet runner using HTTP long polling."

  @impl true
  def functions_mode, do: :stored

  @impl true
  def supports_discovery?, do: true

  @impl true
  def supports_artifacts?, do: true

  @impl true
  def instance_prompt_context(%ToolInstance{} = tool_instance) do
    metadata = Runtime.runner_metadata(tool_instance)

    [
      metadata_line("Runner hostname", metadata_value(metadata, "hostname")),
      metadata_line("Runner platform", platform_summary(metadata)),
      metadata_line("Runner shell", shell_summary(metadata))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      context -> context
    end
  end

  @impl true
  def default_config do
    %{
      "max_concurrency" => 20,
      "poll_max_wait_seconds" => 25.0,
      "runner_online_timeout_seconds" => 60.0,
      "disconnect_grace_seconds" => 300.0
    }
  end

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "max_concurrency" => %{
          "type" => "integer",
          "title" => "Max concurrency",
          "description" => "Maximum concurrent calls per runner.",
          "minimum" => 1
        },
        "poll_max_wait_seconds" => %{
          "type" => "number",
          "title" => "Poll max wait (seconds)",
          "description" => "Maximum long-poll wait time in seconds.",
          "minimum" => 0
        },
        "runner_online_timeout_seconds" => %{
          "type" => "number",
          "title" => "Runner online timeout (seconds)",
          "description" => "How long the runner can stay silent before considered offline.",
          "minimum" => 0
        },
        "disconnect_grace_seconds" => %{
          "type" => "number",
          "title" => "Disconnect grace (seconds)",
          "description" => "How long to wait for a runner after it goes offline.",
          "minimum" => 0
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema do
    %{
      "type" => "object",
      "properties" => %{
        "token" => %{
          "type" => "string",
          "title" => "Runner token",
          "description" => "Outlet runner token.",
          "x-aliases" => ["bearer_token"],
          "x-ui" => %{"placeholder" => "Outlet runner token"}
        }
      }
    }
  end

  @impl true
  def discover(%ToolInstance{} = tool_instance) do
    with {:ok, %{raw: %{} = raw}} <-
           Runtime.enqueue_and_wait(tool_instance, "outlet.list_tools", %{}) do
      discovered_tools_from_raw(raw)
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected outlet response: #{inspect(other)}"}
    end
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, function_name, args, execution_context \\ nil)
      when is_binary(function_name) and is_map(args) do
    case Runtime.enqueue_and_wait(tool_instance, function_name, args, execution_context) do
      {:ok, %{text: _text, raw: _raw, media: _media, artifacts: _artifacts} = result} ->
        {:ok, runtime_execution_result(result)}

      {:error, reason} ->
        {:error, to_string(reason || "Outlet call failed.")}

      other ->
        {:error, "Unexpected outlet response: #{inspect(other)}"}
    end
  end

  @impl IntellectualClub.BackgroundTasks.Adapter
  def execute_background(
        %BackgroundTask{} = task,
        %ToolInstance{} = tool_instance,
        function_name,
        args,
        %ExecutionContext{} = execution_context
      )
      when is_binary(function_name) and is_map(args) do
    with {:ok, identity} <- Runtime.runner_identity(tool_instance),
         :ok <- ensure_runner_session(task, identity),
         {:ok, task} <- bind_runner_session(task, identity),
         {:ok, snapshot} <-
           dispatch_background_start(
             task,
             tool_instance,
             function_name,
             args,
             execution_context
           ) do
      adapter_execution_result(snapshot, identity)
    else
      {:error, :offline} ->
        {:failed,
         %{
           "code" => "outlet_offline",
           "message" => "Outlet runner is offline.",
           "outcome" => "not_started"
         }}

      {:error, :outlet_unavailable, %{} = identity} ->
        {:running, persisted_runner_ref(identity)}

      {:error, :outlet_runner_restarted} ->
        {:failed, outlet_runner_restarted_error()}

      {:error, :outlet_task_expired} ->
        {:failed, outlet_task_expired_error()}

      {:error, reason} ->
        {:failed, outlet_error(reason, "unknown")}
    end
  end

  def execute_background(_task, _tool_instance, _function_name, _args, _execution_context) do
    {:failed,
     %{
       "code" => "invalid_execution_context",
       "message" => "Outlet background execution context is invalid.",
       "outcome" => "not_started"
     }}
  end

  @impl IntellectualClub.BackgroundTasks.Adapter
  def snapshot_background(%BackgroundTask{status: status} = task, cursor)
      when status in [:completed, :failed, :canceled] do
    with {:ok, tool_instance} <- BackgroundTasks.load_tool_instance(task),
         {:ok, identity} <- Runtime.runner_identity(tool_instance),
         :ok <- ensure_runner_session(task, identity),
         {:ok, snapshot} <- dispatch_background_status(task, tool_instance, cursor) do
      {:ok, snapshot}
    else
      {:error, :offline} ->
        {:ok, unavailable_snapshot(task, cursor, :offline)}

      {:error, :outlet_runner_restarted} ->
        {:ok, unavailable_snapshot(task, cursor, :outlet_runner_restarted)}

      {:error, :tool_instance_not_found} ->
        :default

      {:error, reason} ->
        if outlet_unavailable_reason?(reason) do
          {:ok, unavailable_snapshot(task, cursor, reason)}
        else
          {:ok, transient_status_error_snapshot(task, cursor, reason)}
        end
    end
  end

  def snapshot_background(%BackgroundTask{} = task, cursor) do
    cond do
      is_nil(task.tool_instance_id) ->
        {:ok, failed_snapshot(task, cursor, tool_instance_not_found_error())}

      runner_session_bound?(task) ->
        snapshot_bound_background(task, cursor)

      true ->
        {:ok,
         %{
           "status" => Atom.to_string(task.status),
           "progress" => [],
           "next_cursor" => normalize_outlet_cursor(cursor),
           "status_detail" => "outlet_starting"
         }}
    end
  end

  defp snapshot_bound_background(%BackgroundTask{} = task, cursor) do
    with {:ok, tool_instance} <- BackgroundTasks.load_tool_instance(task) do
      case Runtime.runner_identity(tool_instance) do
        {:ok, identity} ->
          with :ok <- ensure_runner_session(task, identity),
               {:ok, snapshot} <-
                 dispatch_background_status(task, tool_instance, cursor) do
            {:ok, snapshot}
          else
            {:error, :outlet_runner_restarted} ->
              {:ok, failed_snapshot(task, cursor, outlet_runner_restarted_error())}

            {:error, reason} ->
              cond do
                outlet_unavailable_reason?(reason) ->
                  {:ok, unavailable_snapshot(task, cursor, reason)}

                outlet_task_expired_reason?(reason) ->
                  {:ok, failed_snapshot(task, cursor, outlet_task_expired_error())}

                outlet_task_not_found_reason?(reason) and not start_acknowledged?(task) ->
                  replay_unacknowledged_start(task, tool_instance, identity, cursor)

                outlet_task_not_found_reason?(reason) ->
                  {:ok, failed_snapshot(task, cursor, outlet_task_not_found_error(reason))}

                true ->
                  {:ok, transient_status_error_snapshot(task, cursor, reason)}
              end
          end

        {:error, :offline} ->
          {:ok, unavailable_snapshot(task, cursor, :offline)}
      end
    else
      {:error, :tool_instance_not_found} ->
        {:ok, failed_snapshot(task, cursor, tool_instance_not_found_error())}
    end
  end

  @impl IntellectualClub.BackgroundTasks.Adapter
  def recover_background(%BackgroundTask{} = task) do
    with {:ok, tool_instance} <- BackgroundTasks.load_tool_instance(task) do
      case Runtime.runner_identity(tool_instance) do
        {:error, :offline} ->
          :keep

        {:ok, identity} ->
          with :ok <- ensure_runner_session(task, identity),
               {:ok, task} <- bind_runner_session(task, identity) do
            if task.cancel_requested == true do
              case cancel_on_runner(task, tool_instance) do
                :ok ->
                  :canceled

                {:error, :outlet_task_expired} ->
                  {:failed, outlet_task_expired_error()}

                {:error, :outlet_task_not_found} ->
                  {:failed, outlet_task_not_found_error(:outlet_task_not_found)}

                {:error, _reason} ->
                  :keep
              end
            else
              execution_context = BackgroundTasks.execution_context(task)

              start_acknowledged? =
                persisted_runner_ref_value(task.runner_ref, "start_acknowledged") == "true"

              dispatch_result =
                if start_acknowledged? do
                  dispatch_background_status(task, tool_instance, nil)
                else
                  dispatch_background_start(
                    task,
                    tool_instance,
                    task.function_name,
                    task.arguments || %{},
                    execution_context
                  )
                end

              case dispatch_result do
                {:ok, snapshot} ->
                  if not start_acknowledged? do
                    _ =
                      BackgroundTasks.update_runner_ref(
                        task,
                        task.runner_ref
                        |> normalize_json_map()
                        |> Map.merge(runner_ref_from_identity(identity))
                        |> Map.put("start_acknowledged", true)
                      )
                  end

                  adapter_recovery_result(snapshot)

                {:error, :outlet_unavailable, _identity} ->
                  :keep

                {:error, :outlet_task_expired} ->
                  {:failed, outlet_task_expired_error()}

                {:error, reason} ->
                  if outlet_task_not_found_reason?(reason) do
                    {:failed, outlet_task_not_found_error(reason)}
                  else
                    {:failed, outlet_error(reason, "unknown")}
                  end
              end
            end
          else
            {:error, :outlet_runner_restarted} ->
              {:failed, outlet_runner_restarted_error()}

            {:error, reason} ->
              {:failed, outlet_error(reason, "unknown")}
          end
      end
    else
      {:error, :tool_instance_not_found} -> {:failed, tool_instance_not_found_error()}
    end
  end

  @impl IntellectualClub.BackgroundTasks.Adapter
  def cancel_background(%BackgroundTask{} = task) do
    if runner_session_bound?(task) do
      cancel_bound_background(task)
    else
      :ok
    end
  end

  defp cancel_bound_background(%BackgroundTask{} = task) do
    result =
      with {:ok, tool_instance} <- BackgroundTasks.load_tool_instance(task) do
        case Runtime.runner_identity(tool_instance) do
          {:ok, identity} ->
            with :ok <- ensure_runner_session(task, identity) do
              cancel_on_runner(task, tool_instance)
            end

          {:error, :offline} ->
            {:error, :outlet_unavailable}
        end
      end

    resolve_cancel_terminal_error(task, result)
  end

  defp resolve_cancel_terminal_error(task, {:error, :outlet_task_expired}) do
    mark_cancel_terminal_failure(
      task,
      "outlet_task_expired",
      outlet_task_expired_error()
    )
  end

  defp resolve_cancel_terminal_error(task, {:error, :outlet_task_not_found}) do
    mark_cancel_terminal_failure(
      task,
      "outlet_task_not_found",
      outlet_task_not_found_error(:outlet_task_not_found)
    )
  end

  defp resolve_cancel_terminal_error(task, {:error, :tool_instance_not_found}) do
    mark_cancel_terminal_failure(
      task,
      "tool_instance_not_found",
      tool_instance_not_found_error()
    )
  end

  defp resolve_cancel_terminal_error(_task, result), do: result

  defp mark_cancel_terminal_failure(task, code, error) do
    case BackgroundTasks.mark_failed(task, code, error, "unknown") do
      {:ok, _task} -> :ok
      {:error, _reason} = failure -> failure
    end
  end

  defp dispatch_background_start(
         %BackgroundTask{} = task,
         %ToolInstance{} = tool_instance,
         function_name,
         args,
         execution_context
       ) do
    case Runtime.background_control_and_wait(
           tool_instance,
           "background_start",
           task.id,
           function_name,
           args,
           nil,
           execution_context,
           persisted_runner_ref(task.runner_ref)
         ) do
      {:ok, result} -> normalize_background_snapshot(result, task.id, nil)
      {:error, reason} -> background_dispatch_error(reason, task)
    end
  end

  defp dispatch_background_status(
         %BackgroundTask{} = task,
         %ToolInstance{} = tool_instance,
         cursor
       ) do
    case Runtime.background_control_and_wait(
           tool_instance,
           "background_status",
           task.id,
           nil,
           %{},
           cursor,
           nil,
           persisted_runner_ref(task.runner_ref)
         ) do
      {:ok, result} ->
        normalize_background_snapshot(result, task.id, cursor)

      {:error, reason} ->
        cond do
          outlet_runner_restarted_reason?(reason) -> {:error, :outlet_runner_restarted}
          outlet_task_expired_reason?(reason) -> {:error, :outlet_task_expired}
          true -> {:error, reason}
        end
    end
  end

  defp replay_unacknowledged_start(task, tool_instance, identity, cursor) do
    execution_context = BackgroundTasks.execution_context(task)

    case dispatch_background_start(
           task,
           tool_instance,
           task.function_name,
           task.arguments || %{},
           execution_context
         ) do
      {:ok, snapshot} ->
        refs =
          task.runner_ref
          |> normalize_json_map()
          |> Map.merge(runner_ref_from_identity(identity))
          |> Map.put("start_acknowledged", true)

        {:ok, Map.put(snapshot, "runner_ref", refs)}

      {:error, :outlet_unavailable, _identity} ->
        {:ok, unavailable_snapshot(task, cursor, :outlet_unavailable)}

      {:error, :outlet_runner_restarted} ->
        {:ok, failed_snapshot(task, cursor, outlet_runner_restarted_error())}

      {:error, :outlet_task_expired} ->
        {:ok, failed_snapshot(task, cursor, outlet_task_expired_error())}

      {:error, reason} ->
        if outlet_unavailable_reason?(reason) do
          {:ok, unavailable_snapshot(task, cursor, reason)}
        else
          {:ok, transient_status_error_snapshot(task, cursor, reason)}
        end
    end
  end

  defp cancel_on_runner(%BackgroundTask{} = task, %ToolInstance{} = tool_instance) do
    case Runtime.background_control_and_wait(
           tool_instance,
           "background_cancel",
           task.id,
           nil,
           %{},
           "0",
           nil,
           persisted_runner_ref(task.runner_ref)
         ) do
      {:ok, result} ->
        with {:ok, snapshot} <- normalize_background_snapshot(result, task.id, "0") do
          case snapshot_value(snapshot, "status") do
            "canceled" ->
              :ok

            "completed" ->
              _ = BackgroundTasks.mark_completed(task, snapshot_result(snapshot))
              :ok

            "failed" ->
              error = snapshot_error(snapshot)

              _ =
                BackgroundTasks.mark_failed(
                  task,
                  Map.get(error, "code", "execution_failed"),
                  error,
                  Map.get(error, "outcome", "unknown")
                )

              :ok

            _other ->
              {:error, :cancel_not_acknowledged}
          end
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        cond do
          outlet_runner_restarted_reason?(reason) ->
            {:error, :outlet_runner_restarted}

          outlet_task_expired_reason?(reason) ->
            {:error, :outlet_task_expired}

          outlet_task_not_found_reason?(reason) and task.status == :queued and
              not start_acknowledged?(task) ->
            :ok

          outlet_task_not_found_reason?(reason) ->
            {:error, :outlet_task_not_found}

          true ->
            {:error, reason}
        end
    end
  end

  defp normalize_background_snapshot(%{raw: %{} = raw}, expected_task_id, cursor) do
    with task_id when is_binary(task_id) <- snapshot_value(raw, "background_task_id"),
         true <- task_id == expected_task_id,
         status when status in ["queued", "running", "completed", "failed", "canceled"] <-
           snapshot_value(raw, "status") do
      {:ok, limit_background_progress_page(raw, cursor)}
    else
      _other -> {:error, :invalid_background_snapshot}
    end
  end

  defp normalize_background_snapshot(_result, _expected_task_id, _cursor),
    do: {:error, :invalid_background_snapshot}

  defp limit_background_progress_page(raw, cursor) do
    progress = snapshot_value(raw, "progress")

    if is_list(progress) do
      {selected, _bytes} =
        Enum.reduce_while(progress, {[], 0}, fn entry, {selected, bytes} ->
          text =
            if is_map(entry),
              do: Map.get(entry, "text", ""),
              else: ""

          entry_bytes = if is_binary(text), do: byte_size(text), else: 0

          if selected != [] and bytes + entry_bytes > @background_progress_page_max_bytes do
            {:halt, {selected, bytes}}
          else
            {:cont, {[entry | selected], bytes + entry_bytes}}
          end
        end)

      selected = Enum.reverse(selected)
      cursor_index = background_cursor_index(cursor)

      selected =
        selected
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, offset} ->
          if is_map(entry) do
            Map.put_new(entry, "cursor", Integer.to_string(cursor_index + offset))
          else
            entry
          end
        end)

      if length(selected) < length(progress) do
        raw
        |> Map.put("progress", selected)
        |> Map.put(
          "next_cursor",
          Integer.to_string(cursor_index + length(selected))
        )
      else
        Map.put(raw, "progress", selected)
      end
    else
      raw
    end
  end

  defp background_cursor_index(cursor) when is_binary(cursor) do
    case Integer.parse(String.trim(cursor)) do
      {value, ""} when value >= 0 -> value
      _other -> 0
    end
  end

  defp background_cursor_index(_cursor), do: 0

  defp adapter_execution_result(snapshot, identity) do
    case snapshot_value(snapshot, "status") do
      status when status in ["queued", "running"] ->
        {:running, Map.put(runner_ref_from_identity(identity), "start_acknowledged", true)}

      "completed" ->
        {:completed, snapshot_result(snapshot)}

      "failed" ->
        {:failed, snapshot_error(snapshot)}

      "canceled" ->
        :canceled
    end
  end

  defp adapter_recovery_result(snapshot) do
    case snapshot_value(snapshot, "status") do
      status when status in ["queued", "running"] -> :keep
      "completed" -> {:completed, snapshot_result(snapshot)}
      "failed" -> {:failed, snapshot_error(snapshot)}
      "canceled" -> :canceled
    end
  end

  defp snapshot_result(snapshot) do
    case snapshot_value(snapshot, "result") do
      %{} = result -> runner_execution_result(result)
      _other -> %ExecutionResult{}
    end
  end

  defp runtime_execution_result(%{
         text: text,
         raw: raw,
         media: media,
         artifacts: artifacts
       }) do
    ExecutionResult.normalize(%ExecutionResult{
      text: text,
      raw: raw,
      media: media,
      artifacts: artifacts
    })
  end

  defp runner_execution_result(result) when is_map(result) do
    ExecutionResult.normalize(%ExecutionResult{
      text: Map.get(result, "text", ""),
      raw: Map.get(result, "raw", %{}),
      media: Map.get(result, "media", []),
      artifacts: Map.get(result, "artifacts", [])
    })
  end

  defp snapshot_error(snapshot) do
    case snapshot_value(snapshot, "error") do
      %{} = error -> error
      reason -> outlet_error(reason || "Outlet background task failed.", "unknown")
    end
  end

  defp bind_runner_session(%BackgroundTask{} = task, identity) do
    refs =
      task.runner_ref
      |> case do
        %{} = existing -> normalize_json_map(existing)
        _other -> %{}
      end
      |> Map.merge(runner_ref_from_identity(identity))

    if task.runner_ref == refs do
      {:ok, task}
    else
      BackgroundTasks.update_runner_ref(task, refs)
    end
  end

  defp ensure_runner_session(%BackgroundTask{} = task, identity) do
    bound_runner_id = persisted_runner_ref_value(task.runner_ref, "runner_id")
    bound_session_id = persisted_runner_ref_value(task.runner_ref, "runner_session_id")
    current = runner_ref_from_identity(identity)

    if (bound_runner_id == "" and bound_session_id == "") or
         (bound_runner_id == current["runner_id"] and
            bound_session_id == current["runner_session_id"]) do
      :ok
    else
      {:error, :outlet_runner_restarted}
    end
  end

  defp runner_ref_from_identity(%{
         runner_id: runner_id,
         runner_session_id: runner_session_id
       }) do
    %{
      "runner_id" => to_string(runner_id),
      "runner_session_id" => to_string(runner_session_id)
    }
  end

  defp persisted_runner_ref(map) when is_map(map) do
    %{
      "runner_id" => persisted_runner_ref_value(map, "runner_id"),
      "runner_session_id" => persisted_runner_ref_value(map, "runner_session_id")
    }
  end

  defp persisted_runner_ref(_map) do
    %{"runner_id" => "", "runner_session_id" => ""}
  end

  defp persisted_runner_ref_value(map, key) when is_map(map) and is_binary(key) do
    map
    |> Map.get(key, "")
    |> to_string()
  end

  defp persisted_runner_ref_value(_map, _key), do: ""

  defp runner_session_bound?(%BackgroundTask{} = task) do
    persisted_runner_ref_value(task.runner_ref, "runner_id") != "" and
      persisted_runner_ref_value(task.runner_ref, "runner_session_id") != ""
  end

  defp start_acknowledged?(%BackgroundTask{} = task) do
    persisted_runner_ref_value(task.runner_ref, "start_acknowledged") == "true"
  end

  defp background_dispatch_error(reason, task) do
    cond do
      outlet_runner_restarted_reason?(reason) ->
        {:error, :outlet_runner_restarted}

      outlet_task_expired_reason?(reason) ->
        {:error, :outlet_task_expired}

      outlet_unavailable_reason?(reason) ->
        identity = task.runner_ref || %{}
        {:error, :outlet_unavailable, identity}

      true ->
        {:error, reason}
    end
  end

  defp outlet_runner_restarted_reason?(reason) do
    reason
    |> safe_error_message()
    |> String.downcase()
    |> String.contains?("runner session replaced")
  end

  defp outlet_unavailable_reason?(:runtime_unavailable), do: true

  defp outlet_unavailable_reason?(reason) do
    reason
    |> safe_error_message()
    |> String.downcase()
    |> then(fn message ->
      String.contains?(message, "runner is offline") or
        String.contains?(message, "runner disconnected") or
        String.contains?(message, "runtime is unavailable") or
        String.contains?(message, "background control timed out")
    end)
  end

  defp outlet_task_not_found_reason?(reason) do
    reason
    |> safe_error_message()
    |> String.downcase()
    |> String.contains?("background task not found")
  end

  defp outlet_task_expired_reason?(:outlet_task_expired), do: true

  defp outlet_task_expired_reason?(reason) do
    reason
    |> safe_error_message()
    |> String.downcase()
    |> String.starts_with?("outlet_task_expired:")
  end

  defp unavailable_snapshot(task, cursor, reason) do
    %{
      "status" => Atom.to_string(task.status),
      "progress" => [],
      "next_cursor" => normalize_outlet_cursor(cursor),
      "status_detail" => "outlet_unavailable",
      "outlet_error" => safe_error_message(reason)
    }
  end

  defp failed_snapshot(task, cursor, error) do
    %{
      "status" => "failed",
      "progress" => [],
      "next_cursor" => normalize_outlet_cursor(cursor),
      "result" => nil,
      "error" => error,
      "runner_ref" => task.runner_ref || %{}
    }
  end

  defp transient_status_error_snapshot(task, cursor, reason) do
    %{
      "status" => Atom.to_string(task.status),
      "progress" => [],
      "next_cursor" => normalize_outlet_cursor(cursor),
      "status_detail" => "outlet_status_error",
      "outlet_error" => safe_error_message(reason)
    }
  end

  defp normalize_outlet_cursor(nil), do: "0"
  defp normalize_outlet_cursor(""), do: "0"
  defp normalize_outlet_cursor(cursor) when is_binary(cursor), do: cursor
  defp normalize_outlet_cursor(cursor), do: to_string(cursor)

  defp outlet_runner_restarted_error do
    %{
      "code" => "outlet_runner_restarted",
      "message" => "Outlet runner session changed before completion.",
      "outcome" => "unknown"
    }
  end

  defp outlet_task_expired_error do
    %{
      "code" => "outlet_task_expired",
      "message" =>
        "Outlet runner no longer retains this task result and will not restart the execution.",
      "outcome" => "unknown"
    }
  end

  defp outlet_task_not_found_error(reason) do
    message =
      case reason do
        :outlet_task_not_found ->
          "Outlet runner no longer has this acknowledged background task."

        value ->
          safe_error_message(value)
      end

    %{
      "code" => "outlet_task_not_found",
      "message" => message,
      "outcome" => "unknown"
    }
  end

  defp tool_instance_not_found_error do
    %{
      "code" => "tool_instance_not_found",
      "message" => "The outlet tool instance was deleted before background execution finished.",
      "outcome" => "unknown"
    }
  end

  defp outlet_error(%{} = reason, fallback_outcome) do
    reason = normalize_json_map(reason)

    %{
      "code" => to_string(Map.get(reason, "code", "outlet_execution_failed")),
      "message" => to_string(Map.get(reason, "message", inspect(reason))),
      "outcome" => to_string(Map.get(reason, "outcome", fallback_outcome))
    }
  end

  defp outlet_error(reason, fallback_outcome) do
    %{
      "code" => "outlet_execution_failed",
      "message" => safe_error_message(reason || "Outlet background execution failed."),
      "outcome" => fallback_outcome
    }
  end

  defp safe_error_message(reason) when is_binary(reason), do: reason
  defp safe_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_message(reason), do: inspect(reason)

  defp snapshot_value(map, key) when is_map(map), do: Map.get(map, key)

  defp normalize_json_map(%{} = value) do
    Map.new(value, fn {key, nested} ->
      nested = if is_map(nested), do: normalize_json_map(nested), else: nested
      {to_string(key), nested}
    end)
  end

  defp metadata_line(_label, ""), do: ""
  defp metadata_line(label, value), do: "#{label}: #{value}"

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    metadata
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp metadata_value(_metadata, _key), do: ""

  defp platform_summary(metadata) when is_map(metadata) do
    platform = metadata_value(metadata, "platform")
    sys_platform = metadata_value(metadata, "sys_platform")
    os_name = metadata_value(metadata, "os_name")

    details =
      []
      |> maybe_append_detail("sys.platform", sys_platform)
      |> maybe_append_detail("os.name", os_name)
      |> Enum.join(", ")

    cond do
      platform != "" and details != "" -> "#{platform} (#{details})"
      platform != "" -> platform
      details != "" -> details
      true -> ""
    end
  end

  defp platform_summary(_metadata), do: ""

  defp shell_summary(metadata) when is_map(metadata) do
    shell_display = metadata_value(metadata, "shell_display")
    shell_kind = metadata_value(metadata, "shell_kind")

    cond do
      shell_display != "" and shell_kind != "" -> "#{shell_display} (kind: #{shell_kind})"
      shell_display != "" -> shell_display
      shell_kind != "" -> shell_kind
      true -> ""
    end
  end

  defp shell_summary(_metadata), do: ""

  defp maybe_append_detail(parts, _label, ""), do: parts
  defp maybe_append_detail(parts, label, value), do: parts ++ ["#{label}=#{value}"]

  @spec discovered_tools_from_raw(map()) :: {:ok, list(map())} | {:error, String.t()}
  def discovered_tools_from_raw(%{} = raw) do
    case Map.get(raw, "tools") do
      tools when is_list(tools) ->
        discovered = Enum.flat_map(tools, &normalize_discovered_tool/1)

        with :ok <- ensure_discovered_tools_present(discovered),
             {:ok, wrappers} <- background_wrappers(discovered) do
          direct = Enum.map(discovered, &Map.drop(&1, ["supports_background"]))
          {:ok, direct ++ wrappers}
        end

      _other ->
        {:error, "Outlet discovery returned an invalid payload."}
    end
  end

  defp normalize_discovered_tool(item) when is_map(item) do
    name = item |> Map.get("name", "") |> to_string() |> String.trim()

    if name == "" do
      []
    else
      description =
        item
        |> Map.get("description", "")
        |> to_string()

      schema =
        cond do
          is_map(Map.get(item, "input_schema")) -> Map.get(item, "input_schema")
          is_map(Map.get(item, "schema")) -> Map.get(item, "schema")
          true -> %{"type" => "object", "properties" => %{}}
        end

      schema =
        if description != "" and Map.get(schema, "description") in [nil, ""] do
          Map.put(schema, "description", description)
        else
          schema
        end

      supports_background = Map.get(item, "supports_background", false) == true

      [
        %{
          "name" => name,
          "description" => description,
          "schema" => schema,
          "supports_background" => supports_background
        }
      ]
    end
  end

  defp normalize_discovered_tool(_item), do: []

  defp ensure_discovered_tools_present([]), do: {:error, "Outlet discovery returned no tools."}
  defp ensure_discovered_tools_present(_discovered), do: :ok

  defp background_wrappers(discovered) when is_list(discovered) do
    names = MapSet.new(discovered, &Map.fetch!(&1, "name"))

    Enum.reduce_while(discovered, {:ok, []}, fn tool, {:ok, wrappers} ->
      if Map.get(tool, "supports_background") == true do
        target = Map.fetch!(tool, "name")
        wrapper_name = target <> "_background"

        if MapSet.member?(names, wrapper_name) do
          {:halt,
           {:error,
            "Outlet discovery background wrapper `#{wrapper_name}` conflicts with a provider function."}}
        else
          wrapper = %{
            "name" => wrapper_name,
            "description" =>
              "Start `#{target}` in the outlet background task pool and return a task id immediately.",
            "schema" => Map.fetch!(tool, "schema"),
            "enabled_by_default" => false,
            "execution_mode" => "background",
            "target_function_name" => target
          }

          {:cont, {:ok, wrappers ++ [wrapper]}}
        end
      else
        {:cont, {:ok, wrappers}}
      end
    end)
  end
end
