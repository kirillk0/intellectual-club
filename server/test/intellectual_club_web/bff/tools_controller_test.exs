defmodule IntellectualClubWeb.Bff.ToolsControllerTest do
  @moduledoc """
  Regression tests for BFF tool endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.{ToolFunction, ToolInstance}

  require Ash.Query

  setup do
    Runtime.reset!()
    :ok
  end

  test "PATCH /api/bff/tool-functions/:id updates function enabled flag", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
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

  test "PATCH /api/bff/tools/:id/fixed-functions/:name creates and updates fixed function overrides",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Fixed function toggle",
          alias: "web",
          config: %{},
          secrets: %{"token" => "token-value"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> patch("/api/bff/tools/#{tool.id}/fixed-functions/web_search", %{"enabled" => false})
      |> json_response(200)

    assert response["name"] == "web_search"
    assert response["enabled"] == false
    assert response["description"] =~ "Search the web"
    assert get_in(response, ["parameters_schema", "required"]) == ["query"]

    overrides =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^tool.id and name == "web_search")
      |> Ash.read!(actor: actor)

    assert length(overrides) == 1
    [override] = overrides
    assert override.enabled == false

    response =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> patch("/api/bff/tools/#{tool.id}/fixed-functions/web_search", %{"enabled" => true})
      |> json_response(200)

    assert response["id"] == override.id
    assert response["enabled"] == true

    overrides =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^tool.id and name == "web_search")
      |> Ash.read!(actor: actor)

    assert length(overrides) == 1
    assert hd(overrides).enabled == true
  end

  test "PATCH /api/bff/tools/:id/fixed-functions/:name rejects unknown fixed function",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Fixed function unknown",
          alias: "web",
          config: %{},
          secrets: %{"token" => "token-value"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> patch("/api/bff/tools/#{tool.id}/fixed-functions/not_a_function", %{"enabled" => false})
      |> json_response(422)

    assert response["error"] =~ "Unknown fixed function"
  end

  test "PATCH /api/bff/tools/:id/fixed-functions/:name rejects shared read-only recipients",
       %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: recipient, password: recipient_password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Shared fixed tool bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: owner
      )
      |> Ash.create!(actor: owner)

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Shared fixed function toggle",
          alias: "web",
          config: %{},
          secrets: %{"token" => "token-value"}
        },
        actor: owner
      )
      |> Ash.create!(actor: owner)

    _ =
      IntellectualClub.Tools.BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: tool.id,
          sharing_mode: :shared,
          enabled: true,
          sequence: 0
        },
        actor: owner
      )
      |> Ash.create!()

    _ = share_bot!(owner, bot, group)

    response =
      conn
      |> sign_in_conn(recipient.username, recipient_password)
      |> patch("/api/bff/tools/#{tool.id}/fixed-functions/web_search", %{"enabled" => false})
      |> json_response(422)

    assert response["error"] =~ "read-only"
  end

  test "POST /api/bff/tools/:id/discover returns reconcile stats for outlet discovery" do
    :sys.replace_state(Runtime, fn _state -> %{instances: %{}, waiter_index: %{}} end)

    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "outlet",
          name: "BFF discover outlet",
          config: %{},
          secrets: %{"token" => "runner-bff-discover"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    runner_payload = %{
      "runner_id" => "runner-bff",
      "runner_session_id" => "runner-bff-session",
      "capacity" => 1,
      "max_wait_seconds" => 0
    }

    initial_poll =
      build_conn()
      |> put_req_header("x-outlet-token", "runner-bff-discover")
      |> post("/api/outlet/poll/", runner_payload)
      |> json_response(200)

    [initial_task] = initial_poll["tasks"]
    assert initial_task["function"] == "outlet.list_tools"

    _initial_complete =
      build_conn()
      |> put_req_header("x-outlet-token", "runner-bff-discover")
      |> post("/api/outlet/complete/", %{
        "call_id" => initial_task["call_id"],
        "runner_id" => "runner-bff",
        "runner_session_id" => "runner-bff-session",
        "status" => "done",
        "result_text" => "{\"tools\":[]}",
        "result_raw" => %{
          "tools" => [
            %{
              "name" => "tool_a",
              "description" => "Old A",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"path" => %{"type" => "string"}}
              }
            },
            %{
              "name" => "tool_b",
              "description" => "Old B",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"query" => %{"type" => "string"}}
              }
            }
          ]
        }
      })
      |> json_response(200)

    discover_task =
      Task.async(fn ->
        build_conn()
        |> sign_in_conn(actor.username, password)
        |> post("/api/bff/tools/#{tool.id}/discover", %{})
        |> json_response(200)
      end)

    task =
      wait_for_task(tool, runner_payload, fn task ->
        Map.get(task, :function, Map.get(task, "function")) == "outlet.list_tools"
      end)

    _manual_complete =
      build_conn()
      |> put_req_header("x-outlet-token", "runner-bff-discover")
      |> post("/api/outlet/complete/", %{
        "call_id" => Map.get(task, :call_id, Map.get(task, "call_id")),
        "runner_id" => "runner-bff",
        "runner_session_id" => "runner-bff-session",
        "status" => "done",
        "result_text" => "{\"tools\":[]}",
        "result_raw" => %{
          "tools" => [
            %{
              "name" => "tool_a",
              "description" => "New A",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"command" => %{"type" => "string"}},
                "required" => ["command"]
              }
            },
            %{
              "name" => "tool_c",
              "description" => "New C",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"target" => %{"type" => "string"}}
              }
            }
          ]
        }
      })
      |> json_response(200)

    response = Task.await(discover_task, 5_000)

    assert response["tool_instance_id"] == tool.id
    assert response["created"] == 1
    assert response["updated"] == 1
    assert response["deleted"] == 1
    assert response["total"] == 2
    assert Enum.map(response["functions"], & &1["name"]) == ["tool_a", "tool_c"]

    functions =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^tool.id)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(functions, & &1.name) == ["tool_a", "tool_c"]
  end

  defp wait_for_task(tool_instance, runner_payload, predicate, attempts \\ 20)

  defp wait_for_task(_tool_instance, _runner_payload, _predicate, 0) do
    flunk("Timed out waiting for outlet discovery task")
  end

  defp wait_for_task(tool_instance, runner_payload, predicate, attempts) do
    case Runtime.poll(tool_instance, runner_payload) do
      {:ok, %{tasks: tasks}} ->
        case Enum.find(tasks, predicate) do
          nil ->
            Process.sleep(25)
            wait_for_task(tool_instance, runner_payload, predicate, attempts - 1)

          task ->
            task
        end

      other ->
        flunk("Unexpected poll result: #{inspect(other)}")
    end
  end

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!()
  end
end
