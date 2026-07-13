defmodule IntellectualClub.Tools.Drivers.OutletTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.Drivers.Outlet
  alias IntellectualClub.Tools.ToolInstance

  setup do
    Runtime.reset!()
    on_exit(&Runtime.reset!/0)
    :ok
  end

  test "discover accepts execution result payload returned by outlet runtime" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "outlet",
        name: "Shell2 outlet",
        config: %{},
        secrets: %{"token" => "runner-token"}
      })

    runner_payload = %{
      "runner_id" => "runner-discovery",
      "runner_session_id" => "runner-discovery",
      "capacity" => 1,
      "max_wait_seconds" => 0
    }

    assert {:ok, %{status: "ok", tasks: [initial_task]}} =
             Runtime.poll(tool_instance, runner_payload)

    assert initial_task.function == "outlet.list_tools"

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => initial_task.call_id,
               "runner_id" => "runner-discovery",
               "runner_session_id" => "runner-discovery",
               "status" => "done",
               "result_text" => "{\"tools\":[]}",
               "result_raw" => %{
                 "tools" => [
                   %{
                     "name" => "bootstrap_tool",
                     "description" => "Bootstrap tool.",
                     "input_schema" => %{
                       "type" => "object",
                       "properties" => %{}
                     }
                   }
                 ]
               },
               "result_media" => [],
               "result_artifacts" => []
             })

    discover_task = Task.async(fn -> Outlet.discover(tool_instance) end)

    task =
      wait_for_task(tool_instance, runner_payload, fn task ->
        Map.get(task, :function, Map.get(task, "function")) == "outlet.list_tools"
      end)

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => Map.get(task, :call_id, Map.get(task, "call_id")),
               "runner_id" => "runner-discovery",
               "runner_session_id" => "runner-discovery",
               "status" => "done",
               "result_text" => "{\"tools\":[]}",
               "result_raw" => %{
                 "tools" => [
                   %{
                     "name" => "read_image",
                     "description" => "Read an image file.",
                     "input_schema" => %{
                       "type" => "object",
                       "properties" => %{
                         "local_path" => %{"type" => "string"}
                       },
                       "required" => ["local_path"],
                       "additionalProperties" => false
                     }
                   }
                 ]
               },
               "result_media" => [],
               "result_artifacts" => []
             })

    assert {:ok,
            [
              %{
                "name" => "read_image",
                "description" => "Read an image file.",
                "schema" => %{
                  "type" => "object",
                  "description" => "Read an image file.",
                  "properties" => %{"local_path" => %{"type" => "string"}},
                  "required" => ["local_path"],
                  "additionalProperties" => false
                }
              }
            ]} = Task.await(discover_task, 5_000)
  end

  test "discovery adds a disabled background wrapper only for capable functions" do
    raw = %{
      "tools" => [
        %{
          "name" => "run_command",
          "description" => "Run a command.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"command" => %{"type" => "string"}}
          },
          "supports_background" => true
        },
        %{
          "name" => "read_image",
          "description" => "Read an image.",
          "input_schema" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }

    assert {:ok, discovered} = Outlet.discovered_tools_from_raw(raw)

    assert Enum.map(discovered, & &1["name"]) == [
             "run_command",
             "read_image",
             "run_command_background"
           ]

    wrapper = Enum.find(discovered, &(&1["name"] == "run_command_background"))
    assert wrapper["enabled_by_default"] == false
    assert wrapper["execution_mode"] == "background"
    assert wrapper["target_function_name"] == "run_command"
    assert wrapper["schema"] == Enum.find(discovered, &(&1["name"] == "run_command"))["schema"]
  end

  test "discovery rejects provider functions colliding with a background wrapper" do
    raw = %{
      "tools" => [
        %{
          "name" => "run_command",
          "description" => "Run.",
          "input_schema" => %{"type" => "object"},
          "supports_background" => true
        },
        %{
          "name" => "run_command_background",
          "description" => "Provider collision.",
          "input_schema" => %{"type" => "object"}
        }
      ]
    }

    assert {:error, message} = Outlet.discovered_tools_from_raw(raw)
    assert message =~ "conflicts"
  end

  test "runtime transports background control operations" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "outlet",
        name: "Background control outlet",
        config: %{},
        secrets: %{"token" => "background-control-token"}
      })

    runner_payload = %{
      "runner_id" => "runner-background-control",
      "runner_session_id" => "runner-background-control-session",
      "capacity" => 1,
      "control_capacity" => 1,
      "max_wait_seconds" => 0
    }

    assert {:ok, %{tasks: [discovery]}} = Runtime.poll(tool_instance, runner_payload)

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => discovery.call_id,
               "runner_id" => runner_payload["runner_id"],
               "runner_session_id" => runner_payload["runner_session_id"],
               "status" => "done",
               "result_raw" => %{"tools" => []}
             })

    control =
      Task.async(fn ->
        Runtime.background_control_and_wait(
          tool_instance,
          "background_start",
          "6feee675-1795-4de6-8b87-f2f11fd75ab0",
          "run_command",
          %{"command" => "echo ready"},
          nil,
          %{owner_id: actor.id}
        )
      end)

    task = wait_for_task(tool_instance, runner_payload, &(&1.operation == "background_start"))
    assert task.background_task_id == "6feee675-1795-4de6-8b87-f2f11fd75ab0"
    assert task.function == "run_command"
    assert task.arguments == %{"command" => "echo ready"}

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => task.call_id,
               "runner_id" => runner_payload["runner_id"],
               "runner_session_id" => runner_payload["runner_session_id"],
               "status" => "done",
               "result_raw" => %{
                 "background_task_id" => task.background_task_id,
                 "status" => "running",
                 "progress" => [],
                 "next_cursor" => "0"
               }
             })

    assert {:ok, result} = Task.await(control, 5_000)
    assert result.raw["background_task_id"] == task.background_task_id
    assert result.raw["status"] == "running"
  end

  test "session-bound background control is rejected instead of moving to a replacement runner" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        name: "Session-bound control outlet",
        secrets: %{"token" => "session-bound-control-token"}
      })

    original = connect_runner!(tool_instance, "session-bound-runner", "session-original")

    control =
      Task.async(fn ->
        Runtime.background_control_and_wait(
          tool_instance,
          "background_start",
          "c583f874-94fe-4bb1-a79e-36c2cecbcc63",
          "run_command",
          %{"command" => "echo once"},
          nil,
          nil,
          %{
            "runner_id" => original["runner_id"],
            "runner_session_id" => original["runner_session_id"]
          }
        )
      end)

    wait_for_pending_operations(tool_instance.id, ["background_start"])

    replacement = %{
      "runner_id" => original["runner_id"],
      "runner_session_id" => "session-replacement",
      "capacity" => 0,
      "control_capacity" => 0,
      "max_wait_seconds" => 0
    }

    assert {:ok, %{status: "idle", tasks: []}} = Runtime.poll(tool_instance, replacement)
    assert {:error, message} = Task.await(control, 5_000)
    assert message =~ "session replaced"

    assert {:ok, %{status: "idle", tasks: []}} =
             Runtime.poll(
               tool_instance,
               Map.merge(replacement, %{"control_capacity" => 1})
             )
  end

  test "control capacity bypasses a pending execute call" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        name: "Control lane outlet",
        config: %{"max_concurrency" => 1},
        secrets: %{"token" => "control-lane-token"}
      })

    runner_payload = connect_runner!(tool_instance, "control-lane-runner", "control-lane-session")

    execute_waiter = enqueue_execute(tool_instance, "first")
    wait_for_pending_operations(tool_instance.id, ["execute"])

    status_waiter = enqueue_control(tool_instance, "background_status", "status-task")
    cancel_waiter = enqueue_control(tool_instance, "background_cancel", "cancel-task")

    wait_for_pending_operations(tool_instance.id, [
      "execute",
      "background_status",
      "background_cancel"
    ])

    assert {:ok, %{status: "ok", tasks: control_tasks}} =
             Runtime.poll(
               tool_instance,
               Map.merge(runner_payload, %{"capacity" => 0, "control_capacity" => 2})
             )

    assert Enum.map(control_tasks, & &1.operation) == [
             "background_status",
             "background_cancel"
           ]

    Enum.each(control_tasks, &complete_task!(tool_instance, runner_payload, &1))
    assert {:ok, _result} = Task.await(status_waiter, 5_000)
    assert {:ok, _result} = Task.await(cancel_waiter, 5_000)

    assert {:ok, %{status: "ok", tasks: [execute_task]}} =
             Runtime.poll(
               tool_instance,
               Map.merge(runner_payload, %{"capacity" => 1, "control_capacity" => 0})
             )

    assert execute_task.operation == "execute"
    complete_task!(tool_instance, runner_payload, execute_task)
    assert {:ok, _result} = Task.await(execute_waiter, 5_000)
  end

  test "legacy runner without control capacity does not claim background controls" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        name: "Legacy control outlet",
        secrets: %{"token" => "legacy-control-token"}
      })

    runner_payload = connect_runner!(tool_instance, "legacy-runner", "legacy-session")
    control_waiter = enqueue_control(tool_instance, "background_status", "legacy-status-task")
    wait_for_pending_operations(tool_instance.id, ["background_status"])

    assert {:ok, %{status: "idle", tasks: []}} =
             Runtime.poll(tool_instance, Map.put(runner_payload, "capacity", 1))

    assert {:ok, %{status: "ok", tasks: [control_task]}} =
             Runtime.poll(
               tool_instance,
               Map.merge(runner_payload, %{"capacity" => 0, "control_capacity" => 1})
             )

    assert control_task.operation == "background_status"
    complete_task!(tool_instance, runner_payload, control_task)
    assert {:ok, _result} = Task.await(control_waiter, 5_000)
  end

  test "active execute and control calls use separate capacity lanes" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        name: "Separate capacity outlet",
        config: %{"max_concurrency" => 1},
        secrets: %{"token" => "separate-capacity-token"}
      })

    runner_payload =
      connect_runner!(tool_instance, "separate-capacity-runner", "separate-capacity-session")

    first_execute_waiter = enqueue_execute(tool_instance, "first")
    wait_for_pending_operations(tool_instance.id, ["execute"])

    assert {:ok, %{tasks: [first_execute]}} =
             Runtime.poll(
               tool_instance,
               Map.merge(runner_payload, %{"capacity" => 1, "control_capacity" => 0})
             )

    control_waiter = enqueue_control(tool_instance, "background_status", "separate-status-task")
    wait_for_pending_operations(tool_instance.id, ["background_status"])

    assert {:ok, %{tasks: [control_task]}} =
             Runtime.poll(
               tool_instance,
               Map.merge(runner_payload, %{"capacity" => 0, "control_capacity" => 1})
             )

    assert first_execute.operation == "execute"
    assert control_task.operation == "background_status"

    complete_task!(tool_instance, runner_payload, first_execute)
    assert {:ok, _result} = Task.await(first_execute_waiter, 5_000)

    second_execute_waiter = enqueue_execute(tool_instance, "second")
    wait_for_pending_operations(tool_instance.id, ["execute"])

    assert {:ok, %{tasks: [second_execute]}} =
             Runtime.poll(
               tool_instance,
               Map.merge(runner_payload, %{"capacity" => 1, "control_capacity" => 0})
             )

    assert second_execute.operation == "execute"
    complete_task!(tool_instance, runner_payload, second_execute)
    complete_task!(tool_instance, runner_payload, control_task)
    assert {:ok, _result} = Task.await(second_execute_waiter, 5_000)
    assert {:ok, _result} = Task.await(control_waiter, 5_000)
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

  defp connect_runner!(tool_instance, runner_id, runner_session_id) do
    runner_payload = %{
      "runner_id" => runner_id,
      "runner_session_id" => runner_session_id,
      "capacity" => 1,
      "max_wait_seconds" => 0
    }

    assert {:ok, %{status: "ok", tasks: [discovery]}} =
             Runtime.poll(tool_instance, runner_payload)

    assert discovery.function == "outlet.list_tools"
    complete_task!(tool_instance, runner_payload, discovery)
    runner_payload
  end

  defp enqueue_execute(tool_instance, label) do
    Task.async(fn ->
      Runtime.enqueue_and_wait(tool_instance, "run_command", %{
        "command" => "echo #{label}"
      })
    end)
  end

  defp enqueue_control(tool_instance, operation, background_task_id) do
    Task.async(fn ->
      Runtime.background_control_and_wait(
        tool_instance,
        operation,
        background_task_id,
        nil,
        %{},
        nil,
        nil
      )
    end)
  end

  defp complete_task!(tool_instance, runner_payload, task) do
    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => task.call_id,
               "runner_id" => runner_payload["runner_id"],
               "runner_session_id" => runner_payload["runner_session_id"],
               "status" => "done",
               "result_text" => "ok",
               "result_raw" => %{
                 "background_task_id" => Map.get(task, :background_task_id),
                 "status" => "running",
                 "progress" => [],
                 "next_cursor" => "0"
               }
             })
  end

  defp wait_for_pending_operations(tool_instance_id, expected, attempts \\ 100)

  defp wait_for_pending_operations(_tool_instance_id, expected, 0) do
    flunk("Timed out waiting for pending outlet operations: #{inspect(expected)}")
  end

  defp wait_for_pending_operations(tool_instance_id, expected, attempts) do
    operations =
      Runtime
      |> :sys.get_state()
      |> get_in([:instances, tool_instance_id, :pending])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, :operation, "execute"))

    available = Enum.frequencies(operations)

    enough_pending? =
      expected
      |> Enum.frequencies()
      |> Enum.all?(fn {operation, count} -> Map.get(available, operation, 0) >= count end)

    if enough_pending? do
      :ok
    else
      Process.sleep(10)
      wait_for_pending_operations(tool_instance_id, expected, attempts - 1)
    end
  end

  defp create_tool_instance!(actor, attrs) when is_map(attrs) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          type: "outlet",
          name: "Outlet",
          config: %{},
          secrets: %{},
          max_output_tokens: 20_000
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!()
  end
end
