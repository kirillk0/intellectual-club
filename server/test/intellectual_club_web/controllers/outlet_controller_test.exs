defmodule IntellectualClubWeb.OutletControllerTest do
  @moduledoc """
  Regression tests for automatic outlet discovery on runner poll.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.{ToolFunction, ToolInstance}

  require Ash.Query

  test "POST /api/outlet/poll enqueues discovery for outlet without functions and complete syncs it",
       %{conn: conn} do
    :sys.replace_state(Runtime, fn _state -> %{instances: %{}, waiter_index: %{}} end)

    %{user: actor} = user_fixture()

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "outlet",
          name: "Auto discovery outlet",
          config: %{},
          secrets: %{"token" => "runner-auto-discovery"}
        },
        actor: actor
      )
      |> Ash.create!()

    refute tool_instance.last_discovered_at
    assert tool_instance.last_discovery_error == ""

    poll_response =
      conn
      |> put_req_header("x-outlet-token", "runner-auto-discovery")
      |> post("/api/outlet/poll/", %{
        "runner_id" => "runner-auto",
        "runner_session_id" => "runner-auto",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })
      |> json_response(200)

    assert poll_response["status"] == "ok"
    [task] = poll_response["tasks"]
    assert task["function"] == "outlet.list_tools"

    _complete_response =
      build_conn()
      |> put_req_header("x-outlet-token", "runner-auto-discovery")
      |> post("/api/outlet/complete/", %{
        "call_id" => task["call_id"],
        "runner_id" => "runner-auto",
        "runner_session_id" => "runner-auto",
        "status" => "done",
        "result_text" => "{\"tools\":[]}",
        "result_raw" => %{
          "tools" => [
            %{
              "name" => "run_command",
              "description" => "Run a shell command.",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{
                  "command" => %{"type" => "string"}
                },
                "required" => ["command"]
              }
            }
          ]
        }
      })
      |> json_response(200)

    functions =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^tool_instance.id)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!(authorize?: false)

    assert Enum.map(functions, & &1.name) == ["run_command"]
    assert Enum.all?(functions, & &1.enabled)

    refreshed = Ash.get!(ToolInstance, tool_instance.id, authorize?: false)
    assert %DateTime{} = refreshed.last_discovered_at
    assert refreshed.last_discovery_error == ""
  end
end
