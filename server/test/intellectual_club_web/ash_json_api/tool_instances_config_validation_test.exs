defmodule IntellectualClubWeb.AshJsonApi.ToolInstancesConfigValidationTest do
  @moduledoc """
  Regression tests for tool instance config validation through Ash JSON:API.
  """

  use IntellectualClubWeb.ConnCase, async: false

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  test "POST /api/ash/tool-instances rejects missing required SSH config fields", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/tool-instances", %{
        "data" => %{
          "type" => "tool-instances",
          "attributes" => %{
            "type" => "ssh",
            "name" => "SSH",
            "config" => %{"host" => "", "username" => ""},
            "secrets" => %{"password" => "secret"},
            "max_output_tokens" => 20_000
          }
        }
      })

    assert conn.status in [400, 422]
    response = json_response(conn, conn.status)
    details = response |> Map.get("errors", []) |> Enum.map(&Map.get(&1, "detail", ""))

    assert Enum.any?(details, &String.contains?(&1, "Host is required."))
    assert Enum.any?(details, &String.contains?(&1, "Username is required."))
  end

  test "POST /api/ash/tool-instances rejects missing required MCP HTTP server URL", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/tool-instances", %{
        "data" => %{
          "type" => "tool-instances",
          "attributes" => %{
            "type" => "mcp-http",
            "name" => "MCP",
            "config" => %{"server_url" => ""},
            "secrets" => %{},
            "max_output_tokens" => 20_000
          }
        }
      })

    assert conn.status in [400, 422]
    response = json_response(conn, conn.status)
    details = response |> Map.get("errors", []) |> Enum.map(&Map.get(&1, "detail", ""))

    assert Enum.any?(details, &String.contains?(&1, "Server URL is required."))
  end
end
