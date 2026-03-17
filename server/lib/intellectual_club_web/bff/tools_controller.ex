defmodule IntellectualClubWeb.Bff.ToolsController do
  @moduledoc """
  BFF endpoints for tool discovery and execution helpers.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Tools.DriverMetadata
  alias IntellectualClub.Tools.{Discovery, ToolInstance}
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
          total: stats.total,
          functions:
            Enum.map(functions, fn fn_record ->
              %{
                id: fn_record.id,
                name: fn_record.name,
                description: fn_record.description,
                parameters_schema: fn_record.parameters_schema,
                enabled: fn_record.enabled,
                discovered_at: Serializer.datetime_iso(fn_record.discovered_at)
              }
            end)
        })
      rescue
        exception ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: Exception.message(exception)})
      end
    end
  end
end
