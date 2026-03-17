defmodule IntellectualClub.Tools.Executor do
  @moduledoc """
  Tool execution utilities for generation.

  This module resolves `alias__function` names into tool instances and executes
  them via the appropriate driver. Outputs are truncated to `max_output_tokens`.
  """

  alias IntellectualClub.TokenCounter
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.Registry

  @truncation_notice "Truncated because length limit"

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
        error_text = to_string(message || "Tool error")

        %ExecutionResult{
          text: error_text,
          raw: %{"isError" => true, "error" => error_text},
          media: [],
          artifacts: []
        }
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

    result =
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
end
