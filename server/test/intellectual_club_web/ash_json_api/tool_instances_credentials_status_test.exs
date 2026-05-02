defmodule IntellectualClubWeb.AshJsonApi.ToolInstancesCredentialsStatusTest do
  @moduledoc """
  Regression tests for tool instance credentials status in Ash JSON:API responses.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Tools.{ToolFunction, ToolInstance}

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  defp relationship_ids(%{"data" => %{"relationships" => relationships}}, rel_name) do
    relationships
    |> Map.get(rel_name, %{})
    |> Map.get("data", [])
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp relationship_ids(_resp, _rel_name), do: []

  defp ids_from_included(%{"included" => included}, type) when is_list(included) do
    included
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp ids_from_included(_resp, _type), do: []

  test "GET /api/ash/tool-instances/:id exposes secrets_present without exposing secrets", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    with_token =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "With token",
          config: %{"server_url" => "https://example.com"},
          secrets: %{"bearer_token" => "super-secret"},
          max_output_tokens: 500
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    without_token =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "Without token",
          config: %{"server_url" => "https://example.net"},
          secrets: %{},
          max_output_tokens: 500
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response_with =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/tool-instances/#{with_token.id}")
      |> json_response(200)

    attrs_with = response_with["data"]["attributes"]
    assert attrs_with["secrets_present"] == ["bearer_token"]
    refute Map.has_key?(attrs_with, "secrets")

    response_without =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/tool-instances/#{without_token.id}")
      |> json_response(200)

    attrs_without = response_without["data"]["attributes"]
    assert attrs_without["secrets_present"] == []
    refute Map.has_key?(attrs_without, "secrets")
  end

  test "GET /api/ash/tool-instances/:id reports SSH credentials status", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    with_password =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "ssh",
          name: "SSH with password",
          config: %{"host" => "example.com", "username" => "root"},
          secrets: %{"password" => "super-secret"},
          max_output_tokens: 500
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    with_private_key =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "ssh",
          name: "SSH with private key",
          config: %{"host" => "example.net", "username" => "ubuntu"},
          secrets: %{"private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----\n..."},
          max_output_tokens: 500
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    attrs_password =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/tool-instances/#{with_password.id}")
      |> json_response(200)
      |> get_in(["data", "attributes"])

    assert attrs_password["secrets_present"] == ["password"]
    refute Map.has_key?(attrs_password, "secrets")

    attrs_private_key =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/tool-instances/#{with_private_key.id}")
      |> json_response(200)
      |> get_in(["data", "attributes"])

    assert attrs_private_key["secrets_present"] == ["private_key"]
    refute Map.has_key?(attrs_private_key, "secrets")
  end

  test "GET /api/ash/tool-instances/:id includes stored functions", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "With functions",
          config: %{"server_url" => "https://example.com"},
          secrets: %{"bearer_token" => "super-secret"},
          max_output_tokens: 500
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    function1 = create_tool_function!(actor, tool, "search")
    function2 = create_tool_function!(actor, tool, "lookup")

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/tool-instances/#{tool.id}?include=functions")
      |> json_response(200)

    assert relationship_ids(response, "functions") == Enum.sort([function1.id, function2.id])

    assert ids_from_included(response, "tool-functions") ==
             Enum.sort([function1.id, function2.id])
  end

  defp create_tool_function!(actor, tool, name) do
    ToolFunction
    |> Ash.Changeset.for_create(
      :create,
      %{
        tool_instance_id: tool.id,
        name: name,
        description: "Function #{name}",
        parameters_schema: %{"type" => "object"},
        enabled: true,
        discovered_at: DateTime.utc_now()
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
