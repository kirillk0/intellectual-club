defmodule IntellectualClub.Tools.Lua.Config do
  @moduledoc """
  Validates Lua tool manifests without parsing or executing their source.

  HTTP permissions belong to `manifest.permissions.http`. Function metadata and
  all configuration keys remain strings. Extraction helpers tolerate incomplete
  configurations, but callers must validate a configuration before executing it.
  """

  alias IntellectualClub.Tools.Lua.{Http, Schema}

  @max_source_bytes 64 * 1024
  @max_functions 32
  @max_description_length 4096
  @function_name ~r/\A[a-zA-Z][a-zA-Z0-9_]{0,63}\z/

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(config) do
    with :ok <- object(config, "config", ~w(source manifest)),
         :ok <- source(Map.get(config, "source")),
         :ok <- manifest(Map.get(config, "manifest")) do
      :ok
    end
  end

  @spec functions(term()) :: [map()]
  def functions(%{"manifest" => %{"functions" => functions}}) when is_list(functions) do
    Enum.flat_map(functions, fn
      %{"name" => name, "description" => description, "input_schema" => schema}
      when is_binary(name) and is_binary(description) and is_map(schema) ->
        [%{"name" => name, "description" => description, "schema" => schema, "enabled" => true}]

      _ ->
        []
    end)
  end

  def functions(_config), do: []

  @spec permissions(term()) :: [map()]
  def permissions(%{"manifest" => %{"permissions" => %{"http" => rules}}}) when is_list(rules),
    do: rules

  def permissions(_config), do: []

  @spec secret_names(term()) :: [String.t()]
  def secret_names(config) do
    config
    |> permissions()
    |> Enum.flat_map(fn
      %{"secrets" => names} when is_list(names) -> Enum.filter(names, &is_binary/1)
      _ -> []
    end)
    |> Enum.uniq()
  end

  @doc "Returns a runnable counter with no HTTP permissions or secrets."
  @spec default() :: map()
  def default do
    %{
      "source" => """
      local exports = {}

      function exports.increment(args, ctx)
        local amount = args.amount or 1
        ctx.state.count = (ctx.state.count or 0) + amount
        return { count = ctx.state.count }
      end

      return exports
      """,
      "manifest" => %{
        "functions" => [
          %{
            "name" => "increment",
            "description" =>
              "Increment the counter shared by this chat family and return its value.",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "amount" => %{
                  "type" => "integer",
                  "description" => "Amount to add to the counter; defaults to 1.",
                  "default" => 1
                }
              },
              "additionalProperties" => false
            }
          }
        ],
        "permissions" => %{"http" => []}
      }
    }
  end

  defp source(value) when is_binary(value) do
    cond do
      byte_size(value) > @max_source_bytes ->
        error("config.source", "must not exceed 65536 bytes (64 KiB)")

      not String.valid?(value) ->
        error("config.source", "must be a valid UTF-8 string")

      true ->
        :ok
    end
  end

  defp source(_value), do: error("config.source", "is required and must be a string")

  defp manifest(value) do
    with :ok <- object(value, "config.manifest", ~w(functions permissions)),
         :ok <- function_list(Map.get(value, "functions")),
         :ok <- permission_object(Map.get(value, "permissions", %{})) do
      :ok
    end
  end

  defp function_list([]),
    do: error("config.manifest.functions", "must contain at least one function")

  defp function_list(functions), do: function_list(functions, 0, MapSet.new())

  defp function_list([], _index, _names), do: :ok

  defp function_list([_function | _rest], @max_functions, _names),
    do: error("config.manifest.functions", "must contain at most 32 functions")

  defp function_list([function | rest], index, names) do
    path = "config.manifest.functions[#{index}]"

    with :ok <- object(function, path, ~w(name description input_schema)),
         :ok <- function_name(Map.get(function, "name"), path),
         :ok <- description(Map.get(function, "description"), path),
         :ok <- input_schema(Map.get(function, "input_schema"), path) do
      name = function["name"]

      if MapSet.member?(names, name) do
        error(path <> ".name", "duplicate function name #{inspect(name)}")
      else
        function_list(rest, index + 1, MapSet.put(names, name))
      end
    end
  end

  defp function_list(_functions, _index, _names),
    do: error("config.manifest.functions", "must be an array of function objects")

  defp function_name(name, path) when is_binary(name) do
    if byte_size(name) <= 64 and Regex.match?(@function_name, name),
      do: :ok,
      else: error(path <> ".name", "must match [a-zA-Z][a-zA-Z0-9_]{0,63}")
  end

  defp function_name(_name, path), do: error(path <> ".name", "is required and must be a string")

  defp description(value, path) when is_binary(value) do
    cond do
      byte_size(value) > @max_description_length * 4 ->
        error(path <> ".description", "must contain at most 4096 Unicode characters")

      not String.valid?(value) ->
        error(path <> ".description", "must be a valid UTF-8 string")

      length(String.to_charlist(value)) > @max_description_length ->
        error(path <> ".description", "must contain at most 4096 Unicode characters")

      true ->
        :ok
    end
  end

  defp description(_value, path),
    do: error(path <> ".description", "is required and must be a string")

  defp input_schema(schema, path) do
    case Schema.validate_schema(schema) do
      :ok ->
        if schema["type"] == "object",
          do: :ok,
          else: error(path <> ".input_schema.type", "must be \"object\" for function arguments")

      {:error, message} ->
        error(path <> ".input_schema", message)
    end
  end

  defp permission_object(value) do
    path = "config.manifest.permissions"

    with :ok <- object(value, path, ~w(http)) do
      case Http.validate_permissions(Map.get(value, "http", [])) do
        :ok -> :ok
        {:error, message} -> error(path <> ".http", message)
      end
    end
  end

  defp object(value, path, allowed) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn {key, _value}, :ok ->
      cond do
        not is_binary(key) or not String.valid?(key) ->
          {:halt, error(path, "object keys must be valid UTF-8 strings")}

        key not in allowed ->
          {:halt, error(path, "unknown field #{inspect(key, printable_limit: 80)}")}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp object(_value, path, _allowed), do: error(path, "must be an object with string keys")

  defp error(path, message), do: {:error, "#{path}: #{message}"}
end
