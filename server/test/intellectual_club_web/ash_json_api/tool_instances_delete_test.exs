defmodule IntellectualClubWeb.AshJsonApi.ToolInstancesDeleteTest do
  @moduledoc """
  Regression tests for tool instance deletion through Ash JSON:API endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Outlets.PairingRequest
  alias IntellectualClub.Tools.{BotToolBinding, BotUserToolBinding, ToolFunction, ToolInstance}

  test "DELETE /api/ash/tool-instances/:id deletes owned tool instance", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp_http",
          name: "Delete me",
          config: %{"server_url" => "https://example.com/mcp"},
          secrets: %{"bearer_token" => "x"},
          max_output_tokens: 2000
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> delete("/api/ash/tool-instances/#{tool.id}")

    assert conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(ToolInstance, tool.id, actor: actor)
  end

  test "DELETE /api/ash/tool-instances/:id removes dependent tool rows and clears pairing references",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Tool deps bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 20,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp_http",
          name: "Delete deps",
          config: %{"server_url" => "https://example.com/mcp"},
          secrets: %{"bearer_token" => "x"},
          max_output_tokens: 2000
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _tool_function =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool.id,
          name: "search",
          description: "",
          parameters_schema: %{"type" => "object"},
          enabled: true,
          discovered_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _bot_binding =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: tool.id,
          alias: "web",
          sharing_mode: :shared,
          enabled: true,
          sequence: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _user_binding =
      BotUserToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: tool.id,
          alias: "user_web",
          enabled: true,
          sequence: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    pairing =
      PairingRequest
      |> Ash.Changeset.for_create(
        :start,
        %{
          user_code: "ABCD-EFGH",
          device_code_hash: "hash",
          runner_kind: "outlet",
          requested_name: "Runner",
          created_user_agent: "test",
          metadata: %{},
          status: "approved",
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        },
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:update, %{tool_instance_id: tool.id}, authorize?: false)
      |> Ash.update!()

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> delete("/api/ash/tool-instances/#{tool.id}")

    assert conn.status in [200, 204], inspect(conn.resp_body)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(ToolInstance, tool.id, actor: actor)

    refute Ash.read!(ToolFunction, actor: actor) |> Enum.any?(&(&1.tool_instance_id == tool.id))
    refute Ash.read!(BotToolBinding, actor: actor) |> Enum.any?(&(&1.tool_instance_id == tool.id))

    refute Ash.read!(BotUserToolBinding, actor: actor)
           |> Enum.any?(&(&1.tool_instance_id == tool.id))

    updated_pairing = Ash.get!(PairingRequest, pairing.id, authorize?: false)
    assert updated_pairing.tool_instance_id == nil
  end
end
