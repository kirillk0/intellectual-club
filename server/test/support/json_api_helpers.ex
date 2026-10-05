defmodule IntellectualClubWeb.JsonApiHelpers do
  @moduledoc """
  Request and response helpers for the AshJsonApi endpoints (`/api/json/...`).

  Imported by `IntellectualClubWeb.ConnCase`.
  """

  import Plug.Conn, only: [put_req_header: 3]

  @endpoint IntellectualClubWeb.Endpoint
  @media_type "application/vnd.api+json"

  @doc "Sends a JSON:API `GET` request."
  def json_api_get(conn, path), do: json_api_request(conn, :get, path, nil)

  @doc "Sends a JSON:API `POST` request with a full JSON:API `document`."
  def json_api_post(conn, path, document), do: json_api_request(conn, :post, path, document)

  @doc "Sends a JSON:API `PATCH` request with a full JSON:API `document`."
  def json_api_patch(conn, path, document), do: json_api_request(conn, :patch, path, document)

  @doc "Sends a JSON:API `DELETE` request."
  def json_api_delete(conn, path), do: json_api_request(conn, :delete, path, nil)

  defp json_api_request(conn, method, path, document) do
    conn
    |> put_req_header("accept", @media_type)
    |> put_req_header("content-type", @media_type)
    |> Phoenix.ConnTest.dispatch(@endpoint, method, path, document)
  end

  @doc """
  Builds a JSON:API document `%{"data" => %{"type" => type, "attributes" => attributes}}`.
  """
  def json_api_data(type, attributes) when is_binary(type) do
    %{"data" => %{"type" => type, "attributes" => attributes}}
  end

  @doc "Returns the sorted integer ids of the primary `data` list of a response."
  def ids_from_data(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(&parse_id(Map.fetch!(&1, "id")))
    |> Enum.sort()
  end

  @doc """
  Returns the sorted integer ids of the `included` records of `type`; `[]` when
  the response has no `included` section.
  """
  def ids_from_included(%{"included" => included}, type) when is_list(included) do
    included
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(&parse_id(Map.fetch!(&1, "id")))
    |> Enum.sort()
  end

  def ids_from_included(_response, _type), do: []

  @doc """
  Returns the sorted integer ids of the relationship `name` of the primary
  record (to-many and to-one relationships); `[]` when absent.
  """
  def relationship_ids(%{"data" => %{"relationships" => relationships}}, name) do
    case relationships |> Map.get(name, %{}) |> Map.get("data") do
      data when is_list(data) -> data |> Enum.map(&parse_id(Map.fetch!(&1, "id"))) |> Enum.sort()
      %{"id" => id} -> [parse_id(id)]
      _other -> []
    end
  end

  def relationship_ids(_response, _name), do: []

  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(id) when is_binary(id), do: String.to_integer(id)
end
