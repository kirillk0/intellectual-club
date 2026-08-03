defmodule IntellectualClubWeb.AshJsonApi.ToolInstancesConfigValidationTest do
  @moduledoc """
  Regression tests for tool instance config validation through Ash JSON:API.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Tools.ToolInstance

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  defp json_api_patch(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, body)
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

  test "POST /api/ash/tool-instances persists MCP config and secrets with string keys", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/tool-instances", %{
        "data" => %{
          "type" => "tool-instances",
          "attributes" => %{
            "type" => "mcp-http",
            "name" => "MCP",
            "config" => %{
              "server_url" => "https://mcp.example.com",
              "open_headers" => %{"X-Tenant-ID" => "tenant-42"},
              "secret_header_names" => ["X-API-Key"]
            },
            "secrets" => %{
              "token" => "mcp-token",
              "secret_headers" => %{"X-API-Key" => "secret-value"}
            },
            "max_output_tokens" => 20_000
          }
        }
      })
      |> json_response(201)

    tool_id = response |> get_in(["data", "id"]) |> String.to_integer()
    tool_instance = Ash.get!(ToolInstance, tool_id, actor: actor)

    assert tool_instance.config == %{
             "server_url" => "https://mcp.example.com",
             "open_headers" => %{"X-Tenant-ID" => "tenant-42"},
             "secret_header_names" => ["X-API-Key"]
           }

    assert tool_instance.secrets == %{
             "bearer_token" => "mcp-token",
             "secret_headers" => %{"X-API-Key" => "secret-value"}
           }
  end

  test "POST /api/ash/tool-instances rejects a secret header without a value", %{conn: conn} do
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
            "config" => %{
              "server_url" => "https://mcp.example.com",
              "open_headers" => %{},
              "secret_header_names" => ["X-Missing"]
            },
            "secrets" => %{"secret_headers" => %{}},
            "max_output_tokens" => 20_000
          }
        }
      })

    assert conn.status in [400, 422]
    response = json_response(conn, conn.status)
    details = response |> Map.get("errors", []) |> Enum.map(&Map.get(&1, "detail", ""))

    assert Enum.any?(details, &String.contains?(&1, "missing a stored value for X-Missing"))
  end

  test "PATCH /api/ash/tool-instances merges nested secret header changes", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "MCP",
          config: %{
            "server_url" => "https://mcp.example.com",
            "open_headers" => %{},
            "secret_header_names" => ["X-Keep", "X-Remove"]
          },
          secrets: %{
            "secret_headers" => %{
              "X-Keep" => "keep-value",
              "X-Remove" => "remove-value"
            }
          }
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn
    |> recycle()
    |> sign_in_conn(actor.username, password)
    |> json_api_patch("/api/ash/tool-instances/#{tool.id}", %{
      "data" => %{
        "id" => to_string(tool.id),
        "type" => "tool-instances",
        "attributes" => %{
          "config" => %{
            "server_url" => "https://mcp.example.com",
            "open_headers" => %{},
            "secret_header_names" => ["X-Keep", "X-New"]
          },
          "secrets" => %{
            "secret_headers" => %{"X-Remove" => "", "X-New" => "new-value"}
          }
        }
      }
    })
    |> json_response(200)

    updated = Ash.get!(ToolInstance, tool.id, actor: actor)

    assert updated.secrets == %{
             "secret_headers" => %{
               "X-Keep" => "keep-value",
               "X-New" => "new-value"
             }
           }
  end
end
