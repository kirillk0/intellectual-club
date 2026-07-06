defmodule IntellectualClub.Tools.Executor do
  @moduledoc """
  Tool execution utilities for generation.

  This module resolves `alias__function` names into tool instances and executes
  them via the appropriate driver. Outputs are truncated to `max_output_tokens`.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.TokenCounter
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.RateLimiter
  alias IntellectualClub.Tools.Registry
  alias IntellectualClub.Tools.ToolFunction

  @null_byte <<0>>
  @truncation_notice "Truncated because length limit"

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
      case function_enabled_for_execution(tool_instance, function_name, execution_context) do
        :ok ->
          case RateLimiter.await_slot(tool_instance) do
            :ok -> execute_driver(tool_instance, function_name, args, execution_context)
            {:error, :busy} -> busy_result()
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

    {truncated_text, truncated?} = truncate_text(result.text, max_output_tokens)

    raw =
      if truncated? do
        truncate_raw(result.raw, truncated_text)
      else
        result.raw
      end

    %ExecutionResult{
      text: truncated_text,
      raw: raw,
      media: result.media,
      artifacts: result.artifacts
    }
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

  defp function_enabled_for_execution(tool_instance, function_name, execution_context) do
    tool_type = tool_instance.type |> to_string() |> String.trim()
    driver = Registry.driver_for_type!(tool_type)

    case driver.functions_mode() do
      :fixed ->
        if fixed_function_enabled?(driver, tool_instance, function_name, execution_context) do
          :ok
        else
          {:error, "Tool function `#{function_name}` is disabled."}
        end

      :stored ->
        if stored_function_enabled?(tool_instance, function_name, execution_context) do
          :ok
        else
          {:error, "Tool function `#{function_name}` is disabled."}
        end
    end
  rescue
    _exception -> :ok
  end

  defp fixed_function_enabled?(driver, tool_instance, function_name, execution_context) do
    fixed =
      if function_exported?(driver, :fixed_functions, 1) do
        driver.fixed_functions(tool_instance)
        |> List.wrap()
        |> Enum.find(&(fixed_function_name(&1) == function_name))
      end

    case fixed do
      nil ->
        true

      fixed ->
        default_enabled = fixed_function_default_enabled?(fixed)

        case fixed_function_override(tool_instance, function_name, execution_context) do
          enabled when is_boolean(enabled) -> enabled
          _other -> default_enabled
        end
    end
  end

  defp stored_function_enabled?(tool_instance, function_name, execution_context) do
    case fixed_function_override(tool_instance, function_name, execution_context) do
      false -> false
      _other -> true
    end
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

  defp truncate_raw(raw, truncated_text) when is_map(raw) do
    out = %{
      "content" => [%{"type" => "text", "text" => truncated_text}],
      "truncated" => true,
      "truncation_notice" => @truncation_notice
    }

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
