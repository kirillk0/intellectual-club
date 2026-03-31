defmodule IntellectualClubWeb.Bff.ToolsController do
  @moduledoc """
  BFF endpoints for tool discovery and execution helpers.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Tools.DriverMetadata
  alias IntellectualClub.Tools.{Discovery, ToolFunction, ToolInstance}
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

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
