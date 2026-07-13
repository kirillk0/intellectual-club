defmodule IntellectualClub.Tools.Executor do
  @moduledoc """
  Tool execution utilities for generation.

  This module resolves `alias__function` names into tool instances and executes
  them via the appropriate driver. Outputs are truncated to `max_output_tokens`.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.TokenCounter
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.RateLimiter
  alias IntellectualClub.Tools.Registry
  alias IntellectualClub.Tools.ToolFunction

  @null_byte <<0>>
  @truncation_notice "Truncated because length limit"
  @terminal_result_notice "BACKGROUND TASK IS TERMINAL. THE TERMINAL RESULT WAS BOUNDED " <>
                            "TO THE OUTPUT LIMIT; DO NOT POLL AGAIN TO RETRIEVE THE OMITTED PART."

  require Ash.Query

  @spec execute_llm_tool(
          map(),
          String.t(),
          map(),
          IntellectualClub.Tools.ExecutionContext.t() | nil
        ) ::
          ExecutionResult.t()
  def execute_llm_tool(tool_instances_by_alias, llm_tool_name, args, execution_context \\ nil)
      when is_map(tool_instances_by_alias) and is_binary(llm_tool_name) and is_map(args) do
    with {:ok, {alias_value, function_name}} <- parse_llm_tool_name(llm_tool_name),
         {:ok, tool_instance} <- resolve_alias(tool_instances_by_alias, alias_value) do
      execute_tool_instance(tool_instance, function_name, args, execution_context)
    else
      {:error, message} ->
        error_text = to_string(message)

        sanitize_execution_result(%ExecutionResult{
          text: error_text,
          raw: %{"isError" => true, "error" => error_text},
          media: [],
          artifacts: []
        })
    end
  end

  defp parse_llm_tool_name(value) do
    value = String.trim(value || "")

    case String.split(value, "__", parts: 2) do
      [alias_value, function_name] when alias_value != "" and function_name != "" ->
        {:ok, {alias_value, function_name}}

      _ ->
        {:error, "Invalid tool name"}
    end
  end

  defp resolve_alias(tool_instances_by_alias, alias_value) when is_map(tool_instances_by_alias) do
    case Map.get(tool_instances_by_alias, alias_value) do
      nil -> {:error, "Unknown tool alias"}
      tool_instance -> {:ok, tool_instance}
    end
  end

  defp execute_tool_instance(tool_instance, function_name, args, execution_context) do
    result =
      case function_execution_spec(tool_instance, function_name, execution_context) do
        {:ok, execution_spec} ->
          case RateLimiter.await_slot(tool_instance) do
            :ok ->
              execute_by_mode(
                execution_spec,
                tool_instance,
                function_name,
                args,
                execution_context
              )

            {:error, :busy} ->
              busy_result()
          end

        {:error, message} ->
          %ExecutionResult{
            text: message,
            raw: %{"isError" => true, "error" => message, "code" => "tool_function_disabled"},
            media: [],
            artifacts: []
          }
      end
      |> sanitize_execution_result()

    max_output_tokens =
      case Map.get(tool_instance, :max_output_tokens) do
        value when is_integer(value) and value >= 0 -> value
        _ -> 20_000
      end

    limit_execution_result(result, max_output_tokens)
  end

  defp execute_by_mode(
         %{execution_mode: :background, target_function_name: target_function_name},
         tool_instance,
         _function_name,
         args,
         execution_context
       )
       when is_binary(target_function_name) and target_function_name != "" do
    case BackgroundTasks.start_tool(
           tool_instance,
           target_function_name,
           args || %{},
           execution_context
         ) do
      {:ok, value} -> ExecutionResult.normalize(value)
      {:error, reason} -> execution_error(reason)
    end
  end

  defp execute_by_mode(
         %{execution_mode: :background},
         _tool_instance,
         function_name,
         _args,
         _execution_context
       ) do
    message =
      "Background tool function `#{function_name}` has no valid target function metadata."

    %ExecutionResult{
      text: message,
      raw: %{
        "isError" => true,
        "error" => message,
        "code" => "invalid_background_function_metadata"
      },
      media: [],
      artifacts: []
    }
  end

  defp execute_by_mode(
         _execution_spec,
         tool_instance,
         function_name,
         args,
         execution_context
       ) do
    execute_driver(tool_instance, function_name, args, execution_context)
  end

  defp execute_driver(tool_instance, function_name, args, execution_context) do
    tool_type = tool_instance.type |> to_string() |> String.trim()

    result =
      try do
        driver = Registry.driver_for_type!(tool_type)
        driver.execute(tool_instance, function_name, args || %{}, execution_context)
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        :exit, reason -> {:error, Exception.format_exit(reason)}
      end

    case result do
      {:ok, value} ->
        ExecutionResult.normalize(value)

      {:error, reason} ->
        %ExecutionResult{
          text: to_string(reason || "Tool execution failed"),
          raw: %{"isError" => true},
          media: [],
          artifacts: []
        }

      other ->
        %ExecutionResult{
          text: "Tool execution failed",
          raw: %{"isError" => true, "raw" => inspect(other)},
          media: [],
          artifacts: []
        }
    end
  end

  defp function_execution_spec(tool_instance, function_name, execution_context) do
    tool_type = tool_instance.type |> to_string() |> String.trim()
    driver = Registry.driver_for_type!(tool_type)

    case driver.functions_mode() do
      :fixed ->
        fixed_function_execution_spec(
          driver,
          tool_instance,
          function_name,
          execution_context
        )

      :stored ->
        stored_function_execution_spec(tool_instance, function_name, execution_context)
    end
  rescue
    _exception ->
      if is_nil(execution_actor(execution_context)) do
        {:ok, %{execution_mode: :direct, target_function_name: nil}}
      else
        {:error, "Tool function `#{function_name}` is unavailable."}
      end
  end

  defp fixed_function_execution_spec(
         driver,
         tool_instance,
         function_name,
         execution_context
       ) do
    fixed =
      if function_exported?(driver, :fixed_functions, 1) do
        driver.fixed_functions(tool_instance)
        |> List.wrap()
        |> Enum.find(&(fixed_function_name(&1) == function_name))
      end

    case fixed do
      nil ->
        {:ok, %{execution_mode: :direct, target_function_name: nil}}

      fixed ->
        default_enabled = fixed_function_default_enabled?(fixed)

        enabled =
          case fixed_function_override(tool_instance, function_name, execution_context) do
            value when is_boolean(value) -> value
            _other -> default_enabled
          end

        if enabled do
          {:ok, normalized_execution_spec(fixed)}
        else
          {:error, "Tool function `#{function_name}` is disabled."}
        end
    end
  end

  defp stored_function_execution_spec(
         %{id: tool_instance_id},
         function_name,
         execution_context
       )
       when is_integer(tool_instance_id) and is_binary(function_name) do
    actor = execution_actor(execution_context)

    if is_nil(actor) do
      {:ok, %{execution_mode: :direct, target_function_name: nil}}
    else
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^tool_instance_id and name == ^function_name)
      |> Ash.Query.select([
        :enabled,
        :discovery_available,
        :execution_mode,
        :target_function_name
      ])
      |> Ash.Query.limit(1)
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %ToolFunction{enabled: true, discovery_available: true} = function} ->
          {:ok, normalized_execution_spec(function)}

        _other ->
          {:error, "Tool function `#{function_name}` is disabled."}
      end
    end
  end

  defp stored_function_execution_spec(_tool_instance, function_name, _execution_context) do
    {:error, "Tool function `#{function_name}` is disabled."}
  end

  defp normalized_execution_spec(raw) when is_map(raw) do
    execution_mode =
      case Map.get(raw, "execution_mode", Map.get(raw, :execution_mode)) do
        value when value in [:background, "background"] -> :background
        _other -> :direct
      end

    target_function_name =
      raw
      |> Map.get("target_function_name", Map.get(raw, :target_function_name))
      |> case do
        value when is_binary(value) -> String.trim(value)
        _other -> nil
      end

    %{execution_mode: execution_mode, target_function_name: target_function_name}
  end

  defp fixed_function_override(%{id: tool_instance_id}, function_name, execution_context)
       when is_integer(tool_instance_id) and is_binary(function_name) do
    actor = execution_actor(execution_context)

    ToolFunction
    |> Ash.Query.filter(tool_instance_id == ^tool_instance_id and name == ^function_name)
    |> Ash.Query.select([:enabled])
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %ToolFunction{enabled: enabled}} when is_boolean(enabled) -> enabled
      _other -> nil
    end
  end

  defp fixed_function_override(_tool_instance, _function_name, _execution_context), do: nil

  defp execution_actor(%{owner_id: owner_id}) when is_integer(owner_id) and owner_id > 0 do
    %User{id: owner_id}
  end

  defp execution_actor(_context), do: nil

  defp fixed_function_name(raw) when is_map(raw) do
    raw
    |> Map.get("name", Map.get(raw, :name, ""))
    |> to_string()
    |> String.trim()
  end

  defp fixed_function_name(_raw), do: ""

  defp fixed_function_default_enabled?(raw) when is_map(raw) do
    case Map.get(raw, "enabled_by_default", Map.get(raw, :enabled_by_default)) do
      value when is_boolean(value) ->
        value

      _other ->
        case Map.get(raw, "enabled", Map.get(raw, :enabled)) do
          false -> false
          _ -> true
        end
    end
  end

  defp fixed_function_default_enabled?(_raw), do: true

  defp busy_result do
    %ExecutionResult{
      text: "Tool is busy. Try again later.",
      raw: %{"isError" => true, "error" => "tool is busy", "code" => "tool_busy"},
      media: [],
      artifacts: []
    }
  end

  defp execution_error(reason) do
    error_text = to_string(reason || "Tool execution failed")

    %ExecutionResult{
      text: error_text,
      raw: %{"isError" => true, "error" => error_text},
      media: [],
      artifacts: []
    }
  end

  @doc false
  @spec sanitize_execution_result(ExecutionResult.t()) :: ExecutionResult.t()
  def sanitize_execution_result(%ExecutionResult{} = result) do
    %ExecutionResult{
      text: sanitize_term(result.text),
      raw: sanitize_term(result.raw),
      media: sanitize_term(result.media),
      artifacts: sanitize_term(result.artifacts)
    }
  end

  @doc false
  @spec limit_execution_result(ExecutionResult.t(), non_neg_integer()) :: ExecutionResult.t()
  def limit_execution_result(%ExecutionResult{} = result, max_output_tokens)
      when is_integer(max_output_tokens) and max_output_tokens >= 0 do
    {truncated_text, truncated?} = truncate_text(result.text, max_output_tokens)

    {text, raw} =
      if truncated? do
        case bounded_terminal_background_result(result.raw, max_output_tokens) do
          {:ok, text, raw} ->
            {text, raw}

          :not_terminal_result ->
            text = background_truncation_text(result.raw, max_output_tokens) || truncated_text
            {text, truncate_raw(result.raw, text)}
        end
      else
        {result.text, result.raw}
      end

    %ExecutionResult{
      text: text,
      raw: raw,
      media: result.media,
      artifacts: result.artifacts
    }
  end

  defp truncate_text(text, max_tokens) when is_binary(text) and is_integer(max_tokens) do
    limit = max(0, max_tokens)

    cond do
      limit == 0 ->
        {@truncation_notice, true}

      TokenCounter.estimate(text) <= limit ->
        {text, false}

      true ->
        notice = "\n\n" <> @truncation_notice
        notice_tokens = TokenCounter.estimate(notice)

        if notice_tokens >= limit do
          {take_tokens(notice, limit), true}
        else
          body = take_tokens(text, limit - notice_tokens)
          {body <> notice, true}
        end
    end
  end

  defp take_tokens(text, max_tokens) when is_binary(text) and is_integer(max_tokens) do
    max_tokens = max(0, max_tokens)

    max_bytes =
      max_tokens
      |> Kernel.*(4)
      |> trunc()
      |> max(0)

    if byte_size(text) <= max_bytes do
      text
    else
      take_valid_prefix(text, max_bytes)
    end
  end

  defp take_valid_prefix(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    max_bytes = max(0, max_bytes)
    prefix = :binary.part(text, 0, max_bytes)

    if String.valid?(prefix) do
      prefix
    else
      # Trim a few bytes to avoid cutting a UTF-8 codepoint.
      prefix =
        Enum.reduce_while(1..4, prefix, fn i, _acc ->
          n = max_bytes - i

          if n <= 0 do
            {:halt, ""}
          else
            candidate = :binary.part(text, 0, n)
            if String.valid?(candidate), do: {:halt, candidate}, else: {:cont, candidate}
          end
        end)

      prefix
    end
  end

  defp bounded_terminal_background_result(raw, max_output_tokens) when is_map(raw) do
    with %{} = snapshot <- Map.get(raw, "background_task"),
         "completed" <- Map.get(snapshot, "status"),
         %{} = result <- Map.get(snapshot, "result"),
         true <- terminal_progress_page_consumable?(snapshot, result, max_output_tokens) do
      {bounded_snapshot, text} =
        fit_bounded_terminal_snapshot(snapshot, result, max_output_tokens)

      {:ok, text, bounded_terminal_raw(raw, bounded_snapshot, text)}
    else
      _other -> :not_terminal_result
    end
  end

  defp bounded_terminal_background_result(_raw, _max_output_tokens),
    do: :not_terminal_result

  defp terminal_progress_page_consumable?(snapshot, result, max_output_tokens) do
    progress = Map.get(snapshot, "progress", [])

    progress == [] or
      snapshot
      |> terminal_snapshot(terminal_result_summary(result, ""))
      |> terminal_snapshot_text()
      |> TokenCounter.estimate()
      |> Kernel.<=(max_output_tokens)
  end

  defp fit_bounded_terminal_snapshot(snapshot, result, max_output_tokens) do
    result_text = result |> Map.get("text", "") |> to_string()
    max_preview_tokens = min(TokenCounter.estimate(result_text), max_output_tokens)

    best =
      fit_terminal_preview(
        snapshot,
        result,
        result_text,
        max_output_tokens,
        0,
        max_preview_tokens,
        nil
      )

    case best do
      {bounded_snapshot, text} ->
        {bounded_snapshot, text}

      nil ->
        bounded_snapshot = terminal_snapshot(snapshot, terminal_result_summary(result, ""))
        {bounded_snapshot, minimum_terminal_result_notice(snapshot)}
    end
  end

  defp fit_terminal_preview(
         _snapshot,
         _result,
         _result_text,
         _max_output_tokens,
         low,
         high,
         best
       )
       when low > high,
       do: best

  defp fit_terminal_preview(
         snapshot,
         result,
         result_text,
         max_output_tokens,
         low,
         high,
         best
       ) do
    preview_tokens = div(low + high, 2)
    preview = take_tokens(result_text, preview_tokens)
    bounded_snapshot = terminal_snapshot(snapshot, terminal_result_summary(result, preview))
    text = terminal_snapshot_text(bounded_snapshot)

    if TokenCounter.estimate(text) <= max_output_tokens do
      fit_terminal_preview(
        snapshot,
        result,
        result_text,
        max_output_tokens,
        preview_tokens + 1,
        high,
        {bounded_snapshot, text}
      )
    else
      fit_terminal_preview(
        snapshot,
        result,
        result_text,
        max_output_tokens,
        low,
        preview_tokens - 1,
        best
      )
    end
  end

  defp terminal_snapshot(snapshot, bounded_result) do
    snapshot
    |> Map.take([
      "background_task_id",
      "kind",
      "status",
      "cancel_requested",
      "target_chat_id",
      "status_detail",
      "url",
      "progress",
      "next_cursor",
      "error",
      "created_at",
      "started_at",
      "finished_at",
      "updated_at"
    ])
    |> Map.put("result", bounded_result)
    |> Map.put("response_truncated", true)
    |> Map.put("page_consumed", true)
    |> Map.put("terminal_result_truncated", true)
  end

  defp terminal_result_summary(result, preview) do
    original_text = result |> Map.get("text", "") |> to_string()
    media = result |> Map.get("media", []) |> List.wrap()
    artifacts = result |> Map.get("artifacts", []) |> List.wrap()

    %{
      "text" => preview,
      "raw" => compact_terminal_raw(Map.get(result, "raw")),
      "media" => [],
      "artifacts" => [],
      "truncated" => true,
      "text_truncated" => preview != original_text,
      "original_text_estimated_tokens" => TokenCounter.estimate(original_text),
      "media_count" => length(media),
      "artifacts_count" => length(artifacts)
    }
  end

  defp compact_terminal_raw(%{} = raw) do
    entries =
      raw
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.take(24)

    compact =
      Map.new(entries, fn {key, value} ->
        {to_string(key), compact_terminal_raw_value(value)}
      end)

    compact
    |> Map.put("background_result_truncated", true)
    |> maybe_put_omitted_key_count(map_size(raw) - length(entries))
  end

  defp compact_terminal_raw(_raw), do: %{"background_result_truncated" => true}

  defp compact_terminal_raw_value(value)
       when is_boolean(value) or is_number(value) or is_nil(value),
       do: value

  defp compact_terminal_raw_value(value) when is_binary(value) do
    if byte_size(value) <= 256 do
      value
    else
      %{
        "truncated" => true,
        "preview" => take_valid_prefix(value, 256),
        "original_bytes" => byte_size(value)
      }
    end
  end

  defp compact_terminal_raw_value(value) when is_map(value) do
    %{"omitted" => true, "type" => "object", "key_count" => map_size(value)}
  end

  defp compact_terminal_raw_value(value) when is_list(value) do
    %{"omitted" => true, "type" => "array", "item_count" => length(value)}
  end

  defp compact_terminal_raw_value(value) do
    %{"omitted" => true, "type" => value |> inspect(limit: 1) |> take_valid_prefix(64)}
  end

  defp maybe_put_omitted_key_count(map, count) when count > 0,
    do: Map.put(map, "omitted_key_count", count)

  defp maybe_put_omitted_key_count(map, _count), do: map

  defp terminal_snapshot_text(snapshot) do
    @terminal_result_notice <>
      "\n\nBackground task snapshot:\n" <> Jason.encode!(snapshot, pretty: true)
  end

  defp minimum_terminal_result_notice(snapshot) do
    task_id = Map.get(snapshot, "background_task_id", "unknown")

    "BACKGROUND_TASK_TERMINAL; RESULT_BOUNDED; PAGE_CONSUMED; DO_NOT_POLL_FOR_OMITTED_RESULT; " <>
      "ID=#{task_id}."
  end

  defp bounded_terminal_raw(raw, bounded_snapshot, text) do
    out = %{
      "content" => [%{"type" => "text", "text" => text}],
      "truncated" => true,
      "truncation_notice" => @truncation_notice,
      "terminal_result_truncated" => true,
      "background_task" => bounded_snapshot,
      "background_task_request" => Map.get(raw, "background_task_request", %{})
    }

    case Map.get(raw, "isError") do
      value when is_boolean(value) -> Map.put(out, "isError", value)
      _other -> out
    end
  end

  defp background_truncation_text(raw, max_output_tokens) when is_map(raw) do
    with %{} = snapshot <- Map.get(raw, "background_task"),
         %{} = request <- Map.get(raw, "background_task_request") do
      retry = background_retry(request)
      minimum_notice = minimum_retry_notice(request)

      text =
        retry_notice(request) <>
          "\n\n" <>
          Jason.encode!(compact_background_snapshot(snapshot, retry), pretty: true)

      if TokenCounter.estimate(minimum_notice) > max_output_tokens do
        minimum_notice
      else
        text
        |> truncate_text(max_output_tokens)
        |> elem(0)
      end
    else
      _other -> nil
    end
  end

  defp background_truncation_text(_raw, _max_output_tokens), do: nil

  defp minimum_retry_notice(%{"operation" => "cancel"}) do
    "CANCEL_REQUESTED; CHECK_STATUS_WITHOUT_CURSOR; DO_NOT_ADVANCE."
  end

  defp minimum_retry_notice(%{"cursor" => nil}) do
    "PAGE_NOT_CONSUMED; RETRY_WITHOUT_CURSOR; DO_NOT_ADVANCE."
  end

  defp minimum_retry_notice(_request) do
    "PAGE_NOT_CONSUMED; RETRY_SAME_CURSOR; DO_NOT_ADVANCE."
  end

  defp retry_notice(%{"operation" => "cancel"}) do
    "CANCELLATION WAS REQUESTED. CHECK STATUS WITHOUT A CURSOR; DO NOT ADVANCE. " <>
      "The response page was not consumed because it exceeded the output limit."
  end

  defp retry_notice(%{"cursor" => nil}) do
    "RETRY THE STATUS CHECK WITHOUT A CURSOR; DO NOT ADVANCE. " <>
      "The response page was not consumed because it exceeded the output limit."
  end

  defp retry_notice(_request) do
    "RETRY THE STATUS CHECK WITH THE SAME CURSOR; DO NOT ADVANCE. " <>
      "The response page was not consumed because it exceeded the output limit."
  end

  defp background_retry(%{"operation" => "cancel"}) do
    %{
      "operation" => "check_background_task_status",
      "cursor" => nil,
      "omit_cursor" => true
    }
  end

  defp background_retry(request) do
    cursor = Map.get(request, "cursor")

    %{
      "operation" => "check_background_task_status",
      "cursor" => cursor,
      "omit_cursor" => is_nil(cursor)
    }
  end

  defp compact_background_snapshot(snapshot, retry) do
    snapshot
    |> Map.take([
      "background_task_id",
      "kind",
      "status",
      "cancel_requested",
      "target_chat_id",
      "error",
      "status_detail",
      "url",
      "created_at",
      "started_at",
      "finished_at",
      "updated_at"
    ])
    |> Map.put("progress", [])
    |> Map.put("response_truncated", true)
    |> Map.put("page_consumed", false)
    |> Map.put("retry", retry)
  end

  defp truncate_raw(raw, truncated_text) when is_map(raw) do
    out = %{
      "content" => [%{"type" => "text", "text" => truncated_text}],
      "truncated" => true,
      "truncation_notice" => @truncation_notice
    }

    out =
      case Map.get(raw, "background_task") do
        %{} = snapshot ->
          request = Map.get(raw, "background_task_request", %{})
          retry = background_retry(request)

          compact =
            compact_background_snapshot(snapshot, retry)

          out
          |> Map.put("background_task", compact)
          |> Map.put("background_task_request", request)

        _other ->
          out
      end

    case Map.get(raw, "isError") do
      value when is_boolean(value) -> Map.put(out, "isError", value)
      _ -> out
    end
  end

  defp sanitize_term(value) when is_binary(value) do
    value
    |> :binary.replace(@null_byte, "", [:global])
    |> ensure_valid_utf8()
  end

  defp sanitize_term(value) when is_list(value) do
    Enum.map(value, &sanitize_term/1)
  end

  defp sanitize_term(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {sanitize_term(key), sanitize_term(nested_value)}
    end)
  end

  defp sanitize_term(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_term/1)
    |> List.to_tuple()
  end

  defp sanitize_term(value), do: value

  defp ensure_valid_utf8(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      :unicode.characters_to_binary(value, :latin1, :utf8)
    end
  end
end
