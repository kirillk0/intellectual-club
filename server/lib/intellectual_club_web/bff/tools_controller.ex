defmodule IntellectualClubWeb.Bff.ToolsController do
  @moduledoc """
  BFF endpoints for tool discovery and execution helpers.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Tools.DriverMetadata
  alias IntellectualClub.Tools.Registry
  alias IntellectualClub.Tools.{Discovery, ToolFunction, ToolInstance}
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  def types(conn, _params) do
    with {:ok, _actor} <- Helpers.require_actor(conn) do
      json(conn, %{types: DriverMetadata.list()})
    end
  end

  def discover(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      tool_instance_id = String.to_integer(id)
      tool_instance = Ash.get!(ToolInstance, tool_instance_id, actor: actor)

      try do
        {stats, functions} = Discovery.discover_and_sync!(tool_instance, actor)

        json(conn, %{
          tool_instance_id: tool_instance_id,
          created: stats.created,
          updated: stats.updated,
          deleted: stats.deleted,
          total: stats.total,
          functions: Enum.map(functions, &serialize_function/1)
        })
      rescue
        exception ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: Exception.message(exception)})
      end
    end
  end

  def update_function(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      try do
        function_id = String.to_integer(id)
        enabled = parse_enabled!(params)

        function =
          ToolFunction
          |> Ash.get!(function_id, actor: actor)
          |> Ash.Changeset.for_update(:update, %{enabled: enabled}, actor: actor)
          |> Ash.update!()

        json(conn, serialize_function(function))
      rescue
        exception ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: Exception.message(exception)})
      end
    end
  end

  def update_fixed_function(conn, %{"id" => id, "name" => function_name} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      try do
        tool_instance_id = String.to_integer(id)
        enabled = parse_enabled!(params)

        tool_instance =
          ToolInstance
          |> Ash.get!(tool_instance_id, actor: actor)
          |> Ash.load!([:can_edit], actor: actor)

        if tool_instance.can_edit != true do
          raise "Tool is read-only"
        end

        driver = Registry.driver_for_type!(to_string(tool_instance.type || ""))

        if driver.functions_mode() != :fixed do
          raise "Tool type does not use fixed functions"
        end

        fixed_function =
          driver
          |> fixed_functions_for(tool_instance)
          |> Enum.find(&(Map.get(&1, :name) == function_name))

        if is_nil(fixed_function) do
          raise "Unknown fixed function: #{function_name}"
        end

        function = upsert_fixed_function_override!(tool_instance, fixed_function, enabled, actor)

        json(conn, serialize_function(function, fixed_function))
      rescue
        exception ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: Exception.message(exception)})
      end
    end
  end

  defp serialize_function(fn_record) do
    %{
      id: fn_record.id,
      name: fn_record.name,
      description: fn_record.description,
      parameters_schema: fn_record.parameters_schema,
      enabled: fn_record.enabled,
      discovered_at: Serializer.datetime_iso(fn_record.discovered_at)
    }
  end

  defp serialize_function(fn_record, fixed_function) do
    %{
      id: fn_record.id,
      name: fixed_function.name,
      description: fixed_function.description,
      parameters_schema: fixed_function.parameters_schema,
      enabled: fn_record.enabled,
      discovered_at: Serializer.datetime_iso(fn_record.discovered_at)
    }
  end

  defp upsert_fixed_function_override!(
         %ToolInstance{} = tool_instance,
         fixed_function,
         enabled,
         actor
       ) do
    case existing_function_override(tool_instance.id, fixed_function.name, actor) do
      nil ->
        ToolFunction
        |> Ash.Changeset.for_create(
          :create,
          %{
            tool_instance_id: tool_instance.id,
            name: fixed_function.name,
            description: fixed_function.description,
            parameters_schema: fixed_function.parameters_schema,
            enabled: enabled,
            discovered_at: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create!()

      %ToolFunction{} = function ->
        function
        |> Ash.Changeset.for_update(
          :update,
          %{
            description: fixed_function.description,
            parameters_schema: fixed_function.parameters_schema,
            enabled: enabled
          },
          actor: actor
        )
        |> Ash.update!()
    end
  end

  defp existing_function_override(tool_instance_id, function_name, actor)
       when is_integer(tool_instance_id) and is_binary(function_name) do
    ToolFunction
    |> Ash.Query.filter(tool_instance_id == ^tool_instance_id and name == ^function_name)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: actor)
    |> List.first()
  end

  defp fixed_functions_for(driver, %ToolInstance{} = tool_instance) do
    if function_exported?(driver, :fixed_functions, 1) do
      driver
      |> apply(:fixed_functions, [tool_instance])
      |> List.wrap()
      |> Enum.map(&normalize_fixed_function/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp normalize_fixed_function(%{} = raw) do
    name = raw |> Map.get("name", Map.get(raw, :name, "")) |> to_string() |> String.trim()

    if name == "" do
      nil
    else
      description =
        raw
        |> Map.get("description", Map.get(raw, :description, ""))
        |> to_string()

      parameters_schema =
        cond do
          is_map(Map.get(raw, "schema")) -> Map.get(raw, "schema")
          is_map(Map.get(raw, :schema)) -> Map.get(raw, :schema)
          is_map(Map.get(raw, "parameters_schema")) -> Map.get(raw, "parameters_schema")
          is_map(Map.get(raw, :parameters_schema)) -> Map.get(raw, :parameters_schema)
          true -> %{"type" => "object", "properties" => %{}}
        end

      %{
        name: name,
        description: description,
        parameters_schema: parameters_schema
      }
    end
  end

  defp normalize_fixed_function(_other), do: nil

  defp parse_enabled!(params) do
    case Map.fetch(params, "enabled") do
      {:ok, value} ->
        case Helpers.parse_boolean(value, nil) do
          value when is_boolean(value) -> value
          _other -> raise ArgumentError, "enabled must be a boolean"
        end

      :error ->
        raise ArgumentError, "enabled is required"
    end
  end
end
