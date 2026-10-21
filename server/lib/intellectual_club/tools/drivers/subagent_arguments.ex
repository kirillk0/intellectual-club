defmodule IntellectualClub.Tools.Drivers.SubagentArguments do
  @moduledoc """
  Shared argument schema and validation for subagent creation functions.

  Fork and spawn primitives accept the same `brief` and `prompt` arguments in
  every driver that exposes them.
  """

  @keys ["brief", "prompt"]

  @spec schema(String.t()) :: map()
  def schema(prompt_description) when is_binary(prompt_description) do
    %{
      "type" => "object",
      "properties" => %{
        "brief" => %{
          "type" => "string",
          "description" => "Short task description stored as the new chat note."
        },
        "prompt" => %{
          "type" => "string",
          "description" => prompt_description
        }
      },
      "required" => @keys,
      "additionalProperties" => false
    }
  end

  @doc """
  Returns trimmed `brief` and `prompt`, rejecting missing, blank, non-string or
  extra fields. `primitive` names the function in error messages.
  """
  @spec parse(map(), String.t()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def parse(args, primitive) when is_map(args) and is_binary(primitive) do
    with :ok <- reject_extra_args(args, primitive),
         {:ok, brief} <- required_trimmed_string(args, "brief"),
         {:ok, prompt} <- required_trimmed_string(args, "prompt") do
      {:ok, brief, prompt}
    end
  end

  defp reject_extra_args(args, primitive) do
    case Map.keys(args) -- @keys do
      [] -> :ok
      _other -> {:error, "#{primitive} arguments contain unsupported fields"}
    end
  end

  defp required_trimmed_string(args, key) do
    case Map.get(args, key) do
      nil ->
        {:error, "#{key} is required"}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "#{key} is required"}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, "#{key} must be a string"}
    end
  end
end
