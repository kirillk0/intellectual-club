defmodule IntellectualClubWeb.Bff.ToolsControllerTest do
  @moduledoc """
  Regression tests for BFF tool endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Tools.{ToolFunction, ToolInstance}

  test "PATCH /api/bff/tool-functions/:id updates function enabled flag", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp_http",
          name: "BFF function toggle",
          config: %{"server_url" => "https://example.com"},
          max_output_tokens: 500
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    function =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool.id,
          name: "toggle_me",
          description: "Toggle me",
          parameters_schema: %{"type" => "object"},
          enabled: false,
          discovered_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> patch("/api/bff/tool-functions/#{function.id}", %{"enabled" => true})
      |> json_response(200)

    assert response["id"] == function.id
    assert response["enabled"] == true

    persisted = Ash.get!(ToolFunction, function.id, actor: actor)
    assert persisted.enabled == true
  end
end
