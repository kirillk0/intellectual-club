defmodule IntellectualClubWeb.OutletControllerTest do
  @moduledoc """
  Regression tests for automatic outlet discovery on runner poll.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.{ToolFunction, ToolInstance}

  require Ash.Query

  setup do
    Runtime.reset!()
    :ok
  end

  test "POST /api/outlet/poll auto-discovers once per runner session and reconciles functions" do
    reset_runtime!()

    %{user: actor} = user_fixture()

    tool_instance =
      create_outlet_tool_instance!(actor, %{
        name: "Auto discovery outlet",
        secrets: %{"token" => "runner-auto-discovery"}
      })

    _existing =
      create_tool_function!(actor, tool_instance.id, %{
        name: "old_tool",
        description: "Outdated tool",
        parameters_schema: %{"type" => "object"},
        enabled: true
      })

    poll_response =
      poll_outlet("runner-auto-discovery", %{
        "runner_id" => "runner-auto",
        "runner_session_id" => "runner-session-1",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert poll_response["status"] == "ok"
    [task] = poll_response["tasks"]
    assert task["function"] == "outlet.list_tools"

    repeated_same_session =
      poll_outlet("runner-auto-discovery", %{
        "runner_id" => "runner-auto",
        "runner_session_id" => "runner-session-1",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert repeated_same_session["status"] == "idle"
    assert repeated_same_session["tasks"] == []

    _complete_response =
      complete_outlet("runner-auto-discovery", %{
        "call_id" => task["call_id"],
        "runner_id" => "runner-auto",
        "runner_session_id" => "runner-session-1",
        "status" => "done",
        "result_text" => "{\"tools\":[]}",
        "result_raw" => %{
          "tools" => [
            %{
              "name" => "run_command",
              "description" => "Run a shell command.",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"command" => %{"type" => "string"}},
                "required" => ["command"]
              }
            }
          ]
        }
      })

    same_session_after_sync =
      poll_outlet("runner-auto-discovery", %{
        "runner_id" => "runner-auto",
        "runner_session_id" => "runner-session-1",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert same_session_after_sync["status"] == "idle"
    assert same_session_after_sync["tasks"] == []

    age_runner!(tool_instance.id, 100_000)

    new_session_response =
      poll_outlet("runner-auto-discovery", %{
        "runner_id" => "runner-auto",
        "runner_session_id" => "runner-session-2",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert new_session_response["status"] == "ok"
    [new_session_task] = new_session_response["tasks"]
    assert new_session_task["function"] == "outlet.list_tools"

    _new_session_complete =
      complete_outlet("runner-auto-discovery", %{
        "call_id" => new_session_task["call_id"],
        "runner_id" => "runner-auto",
        "runner_session_id" => "runner-session-2",
        "status" => "done",
        "result_text" => "{\"tools\":[]}",
        "result_raw" => %{
          "tools" => [
            %{
              "name" => "run_script",
              "description" => "Run a script.",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{"path" => %{"type" => "string"}},
                "required" => ["path"]
              }
            }
          ]
        }
      })

    functions = list_tool_functions(tool_instance.id)

    assert Enum.map(functions, & &1.name) == ["run_script"]
    assert Enum.all?(functions, & &1.enabled)

    refreshed = Ash.get!(ToolInstance, tool_instance.id, authorize?: false)
    assert %DateTime{} = refreshed.last_discovered_at
    assert refreshed.last_discovery_error == ""
  end

  test "POST /api/outlet/poll replaces an online session for the same runner id" do
    reset_runtime!()

    %{user: actor} = user_fixture()

    _tool_instance =
      create_outlet_tool_instance!(actor, %{
        name: "Restartable outlet",
        secrets: %{"token" => "runner-replacement"}
      })

    first_response =
      poll_outlet("runner-replacement", %{
        "runner_id" => "runner-replace",
        "runner_session_id" => "runner-session-1",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert first_response["status"] == "ok"
    [old_task] = first_response["tasks"]

    second_response =
      poll_outlet("runner-replacement", %{
        "runner_id" => "runner-replace",
        "runner_session_id" => "runner-session-2",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert second_response["status"] == "ok"
    [new_task] = second_response["tasks"]
    assert new_task["call_id"] != old_task["call_id"]

    stale_complete =
      complete_outlet_response(
        "runner-replacement",
        %{
          "call_id" => old_task["call_id"],
          "runner_id" => "runner-replace",
          "runner_session_id" => "runner-session-1",
          "status" => "done",
          "result_raw" => %{"tools" => []}
        },
        404
      )

    assert stale_complete["error"] == "Call not found."

    assert %{"status" => "ok"} =
             complete_outlet("runner-replacement", %{
               "call_id" => new_task["call_id"],
               "runner_id" => "runner-replace",
               "runner_session_id" => "runner-session-2",
               "status" => "done",
               "result_raw" => %{"tools" => []}
             })
  end

  test "POST /api/outlet/poll rejects a different runner id while online" do
    reset_runtime!()

    %{user: actor} = user_fixture()

    _tool_instance =
      create_outlet_tool_instance!(actor, %{
        name: "Single runner outlet",
        secrets: %{"token" => "runner-single-active"}
      })

    first_response =
      poll_outlet("runner-single-active", %{
        "runner_id" => "runner-a",
        "runner_session_id" => "runner-a-session",
        "capacity" => 0,
        "max_wait_seconds" => 0
      })

    assert first_response["status"] == "idle"

    conflict_response =
      poll_outlet_response(
        "runner-single-active",
        %{
          "runner_id" => "runner-b",
          "runner_session_id" => "runner-b-session",
          "capacity" => 0,
          "max_wait_seconds" => 0
        },
        409
      )

    assert conflict_response["error"] == "Runner already connected."
  end

  test "POST /api/outlet/poll waits for positive capacity before scheduling auto-discovery" do
    reset_runtime!()

    %{user: actor} = user_fixture()

    _tool_instance =
      create_outlet_tool_instance!(actor, %{
        name: "Capacity-gated outlet",
        secrets: %{"token" => "runner-capacity-gated"}
      })

    zero_capacity_response =
      poll_outlet("runner-capacity-gated", %{
        "runner_id" => "runner-capacity",
        "runner_session_id" => "runner-capacity-session",
        "capacity" => 0,
        "max_wait_seconds" => 0
      })

    assert zero_capacity_response["status"] == "idle"
    assert zero_capacity_response["tasks"] == []

    positive_capacity_response =
      poll_outlet("runner-capacity-gated", %{
        "runner_id" => "runner-capacity",
        "runner_session_id" => "runner-capacity-session",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert positive_capacity_response["status"] == "ok"

    assert Enum.map(positive_capacity_response["tasks"], & &1["function"]) == [
             "outlet.list_tools"
           ]
  end

  test "POST /api/outlet/complete records auto-discovery errors without changing stored functions" do
    reset_runtime!()

    %{user: actor} = user_fixture()

    tool_instance =
      create_outlet_tool_instance!(actor, %{
        name: "Auto discovery error outlet",
        secrets: %{"token" => "runner-auto-error"}
      })

    _existing =
      create_tool_function!(actor, tool_instance.id, %{
        name: "keep_tool",
        description: "Keep me",
        parameters_schema: %{"type" => "object"},
        enabled: true
      })

    poll_response =
      poll_outlet("runner-auto-error", %{
        "runner_id" => "runner-error",
        "runner_session_id" => "runner-error-session",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert poll_response["status"] == "ok"
    [task] = poll_response["tasks"]
    assert task["function"] == "outlet.list_tools"

    _complete_response =
      complete_outlet("runner-auto-error", %{
        "call_id" => task["call_id"],
        "runner_id" => "runner-error",
        "runner_session_id" => "runner-error-session",
        "status" => "done",
        "result_text" => "{\"tools\":\"bad\"}",
        "result_raw" => %{"tools" => "bad"}
      })

    functions = list_tool_functions(tool_instance.id)
    assert Enum.map(functions, & &1.name) == ["keep_tool"]

    refreshed = Ash.get!(ToolInstance, tool_instance.id, authorize?: false)
    refute refreshed.last_discovered_at
    assert refreshed.last_discovery_error == "Outlet discovery returned an invalid payload."
  end

  test "runtime exposes online runner metadata for outlet instance prompt context" do
    reset_runtime!()

    %{user: actor} = user_fixture()

    tool_instance =
      create_outlet_tool_instance!(actor, %{
        name: "Metadata outlet",
        secrets: %{"token" => "runner-metadata"}
      })

    _poll_response =
      poll_outlet("runner-metadata", %{
        "runner_id" => "runner-metadata",
        "runner_session_id" => "runner-metadata-session",
        "capacity" => 1,
        "max_wait_seconds" => 0,
        "metadata" => %{
          "hostname" => "worker-1",
          "platform" => "linux",
          "sys_platform" => "linux",
          "os_name" => "posix",
          "shell_kind" => "bash",
          "shell_display" => "/bin/bash -c"
        }
      })

    assert Runtime.runner_metadata(tool_instance)["platform"] == "linux"

    assert {:error, :not_found} =
             Runtime.complete(tool_instance, %{
               "runner_id" => "runner-metadata",
               "runner_session_id" => "runner-metadata-session",
               "call_id" => "missing-call"
             })

    assert Runtime.runner_metadata(tool_instance)["platform"] == "linux"

    context = IntellectualClub.Tools.Drivers.Outlet.instance_prompt_context(tool_instance)

    assert String.contains?(context, "Runner hostname: worker-1")
    assert String.contains?(context, "Runner platform: linux")
    assert String.contains?(context, "Runner shell: /bin/bash -c (kind: bash)")

    age_runner!(tool_instance.id, 100_000)

    assert Runtime.runner_metadata(tool_instance) == %{}
    assert IntellectualClub.Tools.Drivers.Outlet.instance_prompt_context(tool_instance) == nil
  end

  test "POST /api/outlet/calls/:call_id/files accepts unicode filename query parameter" do
    reset_runtime!()

    %{user: actor} = user_fixture()

    _tool_instance =
      create_outlet_tool_instance!(actor, %{
        name: "Unicode upload outlet",
        secrets: %{"token" => "runner-unicode-upload"}
      })

    poll_response =
      poll_outlet("runner-unicode-upload", %{
        "runner_id" => "runner-upload",
        "runner_session_id" => "runner-upload-session",
        "capacity" => 1,
        "max_wait_seconds" => 0
      })

    assert poll_response["status"] == "ok"
    [task] = poll_response["tasks"]

    filename = "отчет.txt"

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer runner-unicode-upload")
      |> put_req_header("content-type", "text/plain")
      |> post(
        "/api/outlet/calls/#{task["call_id"]}/files?filename=#{URI.encode_www_form(filename)}",
        "payload"
      )
      |> json_response(200)

    assert response["file"]["filename"] == filename
    assert response["file"]["mime_type"] == "text/plain"
    assert response["file"]["size_bytes"] == 7
  end

  defp reset_runtime! do
    :sys.replace_state(Runtime, fn _state -> %{instances: %{}, waiter_index: %{}} end)
  end

  defp age_runner!(tool_instance_id, age_ms)
       when is_integer(tool_instance_id) and is_integer(age_ms) do
    :sys.replace_state(Runtime, fn state ->
      update_in(state.instances[tool_instance_id].runner.last_seen_ms, &(&1 - age_ms))
    end)
  end

  defp poll_outlet(token, payload) when is_binary(token) and is_map(payload) do
    poll_outlet_response(token, payload, 200)
  end

  defp poll_outlet_response(token, payload, status)
       when is_binary(token) and is_map(payload) and is_integer(status) do
    build_conn()
    |> put_req_header("x-outlet-token", token)
    |> post("/api/outlet/poll/", payload)
    |> json_response(status)
  end

  defp complete_outlet(token, payload) when is_binary(token) and is_map(payload) do
    complete_outlet_response(token, payload, 200)
  end

  defp complete_outlet_response(token, payload, status)
       when is_binary(token) and is_map(payload) and is_integer(status) do
    build_conn()
    |> put_req_header("x-outlet-token", token)
    |> post("/api/outlet/complete/", payload)
    |> json_response(status)
  end

  defp list_tool_functions(tool_instance_id) when is_integer(tool_instance_id) do
    ToolFunction
    |> Ash.Query.filter(tool_instance_id == ^tool_instance_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp create_outlet_tool_instance!(actor, attrs) when is_map(attrs) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          type: "outlet",
          name: "Outlet",
          config: %{},
          secrets: %{"token" => "runner-token"}
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_tool_function!(actor, tool_instance_id, attrs) when is_integer(tool_instance_id) do
    ToolFunction
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          tool_instance_id: tool_instance_id,
          name: "tool",
          description: "",
          parameters_schema: %{"type" => "object"},
          enabled: true,
          discovered_at: DateTime.utc_now()
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!()
  end
end
