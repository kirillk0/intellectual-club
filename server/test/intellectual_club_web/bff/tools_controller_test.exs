defmodule IntellectualClubWeb.Bff.ToolsControllerTest do
  @moduledoc """
  Tool BFF endpoints: types, discovery, function settings and runtime status.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.ToolFunction
  alias IntellectualClub.Tools.ToolInstance
  alias IntellectualClub.Tools.ToolInstanceShare

  require Ash.Query

  describe "tool types, discovery and functions" do
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

    test "stored interruption safety is an independent owner-only boolean setting", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      %{user: outsider, password: other_password} = user_fixture()
      tool = create_tool_instance!(actor)
      function = create_tool_function!(actor, tool, enabled: false)
      owner_conn = sign_in_conn(conn, actor.username, password)
      path = "/api/bff/tool-functions/#{function.id}"
      response = owner_conn |> patch(path, %{"safe_to_interrupt" => true}) |> json_response(200)
      assert response["safe_to_interrupt"] == true
      assert response["enabled"] == false
      persisted = Ash.get!(ToolFunction, function.id, actor: actor)
      assert persisted.safe_to_interrupt
      refute persisted.enabled

      rejected =
        build_conn()
        |> sign_in_conn(outsider.username, other_password)
        |> patch(path, %{"safe_to_interrupt" => false})

      assert rejected.status in [403, 404, 422]
      assert Ash.get!(ToolFunction, function.id, actor: actor).safe_to_interrupt
      invalid = owner_conn |> patch(path, %{"safe_to_interrupt" => "maybe"}) |> json_response(422)
      assert invalid["error"] =~ "safe_to_interrupt must be a boolean"
    end

    test "background-start policy is exposed and cannot opt into automatic interruption", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      tool = create_tool_instance!(actor)

      function =
        create_tool_function!(actor, tool,
          name: "search_background",
          execution_mode: :background,
          target_function_name: "search"
        )

      signed_in = sign_in_conn(conn, actor.username, password)

      document =
        signed_in
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/ash/tool-instances/#{tool.id}?include=functions")
        |> json_response(200)

      exposed =
        Enum.find(
          document["included"],
          &(&1["id"] == to_string(function.id) and &1["type"] == "tool-functions")
        )

      assert exposed["attributes"]["execution_mode"] == "background"
      assert exposed["attributes"]["safe_to_interrupt"] == false

      rejected =
        signed_in
        |> patch("/api/bff/tool-functions/#{function.id}", %{"safe_to_interrupt" => true})
        |> json_response(422)

      assert rejected["error"] =~ "cannot be enabled for background-start functions"
      refute Ash.get!(ToolFunction, function.id, actor: actor).safe_to_interrupt
    end

    test "PATCH /api/bff/tools/:id/fixed-functions/:name creates and updates fixed function overrides",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()

      tool =
        ToolInstance
        |> Ash.Changeset.for_create(
          :create,
          %{
            type: "native-web-search",
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

      assert response["safe_to_interrupt"] == true
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
            type: "native-web-search",
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
            type: "native-web-search",
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
  end

  describe "GET /api/bff/tools/status" do
    setup do
      Runtime.reset!()
      on_exit(fn -> Runtime.reset!() end)
      :ok
    end

    test "returns only requested accessible outlet statuses and reflects presence changes", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      %{user: other} = user_fixture()

      online =
        create_tool_instance!(actor, type: "outlet")

      offline =
        create_tool_instance!(actor, type: "outlet")

      _unrequested =
        create_tool_instance!(actor, type: "outlet")

      private =
        create_tool_instance!(other, type: "outlet")

      other_type =
        create_tool_instance!(actor, type: "native-web-search")

      assert {:ok, _} =
               Runtime.poll(online, %{
                 "runner_id" => "status-runner",
                 "capacity" => 0,
                 "max_wait_seconds" => 0
               })

      conn = sign_in_conn(conn, actor.username, password)

      path =
        "/api/bff/tools/status?ids=#{online.id},#{offline.id},#{private.id},#{other_type.id},#{online.id}"

      response = get(conn, path)
      assert get_resp_header(response, "cache-control") == ["no-store"]

      assert Enum.sort_by(json_response(response, 200)["tools"], & &1["id"]) == [
               %{"id" => online.id, "outlet_online" => true},
               %{"id" => offline.id, "outlet_online" => false}
             ]

      :sys.replace_state(Runtime, fn state ->
        update_in(state, [:instances, online.id, :runner, :last_seen_ms], &(&1 - 61_000))
      end)

      response = conn |> get(path) |> json_response(200)
      assert Enum.all?(response["tools"], &(&1["outlet_online"] == false))
    end

    test "honors direct sharing and revocation", %{conn: conn} do
      %{user: owner} = user_fixture()
      %{user: recipient, password: password} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})

      tool =
        create_tool_instance!(owner, type: "outlet")

      share =
        ToolInstanceShare
        |> Ash.Changeset.for_create(
          :create,
          %{tool_instance_id: tool.id, user_group_id: group.id},
          actor: owner
        )
        |> Ash.create!(actor: owner)

      conn = sign_in_conn(conn, recipient.username, password)
      path = "/api/bff/tools/status?ids=#{tool.id}"

      assert conn |> get(path) |> json_response(200) == %{
               "tools" => [%{"id" => tool.id, "outlet_online" => false}]
             }

      Ash.destroy!(share, actor: owner)
      assert conn |> get(path) |> json_response(200) == %{"tools" => []}
    end

    test "requires authentication and validates bounded positive IDs", %{conn: conn} do
      assert conn |> get("/api/bff/tools/status?ids=1") |> json_response(401)
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      for ids <- [
            nil,
            "",
            "0",
            "-1",
            "1,invalid",
            "1,",
            "9223372036854775808",
            Enum.join(1..201, ","),
            ["1"]
          ] do
        response =
          get(conn, "/api/bff/tools/status", if(is_nil(ids), do: %{}, else: %{"ids" => ids}))

        assert json_response(response, 422)["error"] =~ "ids must contain"
      end
    end
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
end
