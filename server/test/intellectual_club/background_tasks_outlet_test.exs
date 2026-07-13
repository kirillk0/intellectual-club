defmodule IntellectualClub.BackgroundTasksOutletTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.BackgroundTasks.Reaper
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.Drivers.Outlet
  alias IntellectualClub.Tools.ToolFunction
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  setup do
    Runtime.reset!()
    on_exit(&Runtime.reset!/0)
    :ok
  end

  test "offline launch fails with a not_started outcome" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    task_id = launch_background!(actor, tool_instance, "echo offline")
    task = wait_for_task_status(task_id, actor.id, :failed)

    assert task.error["code"] == "outlet_offline"
    assert task.error["outcome"] == "not_started"

    assert {:ok, snapshot} = BackgroundTasks.snapshot(task_id, nil, actor.id)
    assert snapshot["status"] == "failed"
    assert snapshot["error"]["code"] == "outlet_offline"
    assert snapshot["error"]["outcome"] == "not_started"
  end

  test "queued outlet recovery waits offline and starts after a runner connects" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    task = create_outlet_background_task!(actor, tool_instance, %{status: :queued})

    assert :ok = BackgroundTasks.recover()
    Process.sleep(50)

    assert {:ok, %{status: :queued}} = load_owned_task(task.id, actor.id)
    assert Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id) == []

    runner = connect_runner!(tool_instance, "runner-queued", "session-queued")
    start_call = wait_for_control_call!(tool_instance, runner, "background_start")

    assert start_call.background_task_id == task.id
    assert start_call.function == "run_command"

    complete_background_call!(tool_instance, runner, start_call, %{
      "background_task_id" => task.id,
      "status" => "completed",
      "progress" => [],
      "next_cursor" => "0",
      "result" => %{"text" => "queued", "raw" => %{}, "media" => [], "artifacts" => []}
    })

    _completed = wait_for_task_status(task.id, actor.id, :completed)
  end

  test "live reaper starts a lost queued outlet worker when its runner is online" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    runner = connect_runner!(tool_instance, "runner-live-reaper", "session-live-reaper")
    task = create_outlet_background_task!(actor, tool_instance, %{status: :queued})

    assert :ok = Reaper.sweep()

    start_call = wait_for_control_call!(tool_instance, runner, "background_start")
    assert start_call.background_task_id == task.id
    assert start_call.function == "run_command"

    complete_background_call!(tool_instance, runner, start_call, %{
      "background_task_id" => task.id,
      "status" => "completed",
      "progress" => [],
      "next_cursor" => "0",
      "result" => %{"text" => "reaped", "raw" => %{}, "media" => [], "artifacts" => []}
    })

    completed = wait_for_task_status(task.id, actor.id, :completed)
    assert completed.result["text"] == "reaped"
  end

  test "launch returns a UUID before background_start completes in the same runner session" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    runner = connect_runner!(tool_instance, "runner-immediate", "session-immediate")
    task_id = launch_background!(actor, tool_instance, "echo immediate")

    assert Ecto.UUID.cast(task_id) == {:ok, task_id}

    start_call = wait_for_control_call!(tool_instance, runner, "background_start")
    assert start_call.background_task_id == task_id
    assert start_call.function == "run_command"
    assert start_call.arguments == %{"command" => "echo immediate"}

    complete_background_call!(tool_instance, runner, start_call, %{
      "background_task_id" => task_id,
      "status" => "running",
      "progress" => [],
      "next_cursor" => "0"
    })

    wait_for_worker_exit(task_id)
    task = wait_for_task_status(task_id, actor.id, :running)

    assert task.runner_ref["runner_id"] == runner["runner_id"]
    assert task.runner_ref["runner_session_id"] == runner["runner_session_id"]
    assert task.runner_ref["start_acknowledged"] == true

    Runtime.reset!()
    reconnected = connect_runner!(tool_instance, "runner-immediate", "session-immediate")
    status_call = wait_for_control_call!(tool_instance, reconnected, "background_status")

    assert status_call.background_task_id == task_id

    complete_background_call!(tool_instance, reconnected, status_call, %{
      "background_task_id" => task_id,
      "status" => "completed",
      "progress" => [],
      "next_cursor" => "0",
      "result" => %{"text" => "done", "raw" => %{}, "media" => [], "artifacts" => []}
    })

    _completed = wait_for_task_status(task_id, actor.id, :completed)
  end

  test "runtime restart after dispatch keeps the start unacknowledged and replays the same task" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    runner = connect_runner!(tool_instance, "runner-runtime-restart", "session-runtime-restart")

    task_id = launch_background!(actor, tool_instance, "echo after runtime restart")
    accepted_start = wait_for_control_call!(tool_instance, runner, "background_start")

    assert accepted_start.background_task_id == task_id
    assert accepted_start.function == "run_command"
    assert accepted_start.arguments == %{"command" => "echo after runtime restart"}

    on_exit(&ensure_outlet_runtime_started/0)

    assert :ok =
             Supervisor.terminate_child(
               IntellectualClub.Supervisor,
               IntellectualClub.Outlets.Runtime
             )

    wait_for_worker_exit(task_id)
    task = wait_for_task_status(task_id, actor.id, :running)

    assert task.runner_ref["runner_id"] == runner["runner_id"]
    assert task.runner_ref["runner_session_id"] == runner["runner_session_id"]
    refute task.runner_ref["start_acknowledged"]
    refute task.error

    assert {:ok, _runtime_pid} =
             Supervisor.restart_child(
               IntellectualClub.Supervisor,
               IntellectualClub.Outlets.Runtime
             )

    reconnected =
      connect_runner!(
        tool_instance,
        "runner-runtime-restart",
        "session-runtime-restart"
      )

    replayed_start = wait_for_control_call!(tool_instance, reconnected, "background_start")

    assert replayed_start.call_id != accepted_start.call_id
    assert replayed_start.background_task_id == accepted_start.background_task_id
    assert replayed_start.function == accepted_start.function
    assert replayed_start.arguments == accepted_start.arguments

    complete_background_call!(tool_instance, reconnected, replayed_start, %{
      "background_task_id" => task_id,
      "status" => "completed",
      "progress" => [],
      "next_cursor" => "0",
      "result" => %{
        "text" => "replayed after runtime restart",
        "raw" => %{},
        "media" => [],
        "artifacts" => []
      }
    })

    completed = wait_for_task_status(task_id, actor.id, :completed)
    assert completed.result["text"] == "replayed after runtime restart"
  end

  test "executor routes an enabled wrapper through stored background metadata" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    _wrapper =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool_instance.id,
          name: "command_later",
          description: "Run a command in the background.",
          parameters_schema: %{"type" => "object"},
          enabled: true,
          execution_mode: :background,
          target_function_name: "run_command"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    source = create_source_tool_call!(actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.chat.id,
      message_id: source.message.id,
      assistant_message_id: source.message.id,
      step_id: source.step.id,
      tool_call_item_id: source.item.id,
      available_file_external_ids: []
    }

    runner = connect_runner!(tool_instance, "runner-metadata", "session-metadata")

    launch =
      Executor.execute_llm_tool(
        %{"outlet" => tool_instance},
        "outlet__command_later",
        %{"command" => "echo metadata"},
        context
      )

    task_id = launch.raw["background_task_id"]
    assert Ecto.UUID.cast(task_id) == {:ok, task_id}
    assert launch.raw["kind"] == "outlet_function"

    start_call = wait_for_control_call!(tool_instance, runner, "background_start")
    assert start_call.background_task_id == task_id
    assert start_call.function == "run_command"
    refute start_call.function == "command_later"

    complete_background_call!(tool_instance, runner, start_call, %{
      "background_task_id" => task_id,
      "status" => "completed",
      "progress" => [],
      "next_cursor" => "0",
      "result" => %{"text" => "done", "raw" => %{}, "media" => [], "artifacts" => []}
    })

    _completed = wait_for_task_status(task_id, actor.id, :completed)
  end

  test "background wrapper metadata fails closed instead of invoking the wrapper directly" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    wrapper =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool_instance.id,
          name: "broken_background",
          description: "Broken background metadata.",
          parameters_schema: %{"type" => "object"},
          enabled: true,
          execution_mode: :direct
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    # Simulate legacy or externally corrupted metadata that predates validation.
    {1, nil} =
      IntellectualClub.Repo.update_all(
        from(function in "tool_functions", where: function.id == ^wrapper.id),
        set: [execution_mode: "background", target_function_name: nil]
      )

    source = create_source_tool_call!(actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.chat.id,
      message_id: source.message.id,
      assistant_message_id: source.message.id,
      step_id: source.step.id,
      tool_call_item_id: source.item.id,
      available_file_external_ids: []
    }

    result =
      Executor.execute_llm_tool(
        %{"outlet" => tool_instance},
        "outlet__broken_background",
        %{"command" => "echo must-not-run"},
        context
      )

    assert result.raw["isError"] == true
    assert result.raw["code"] == "invalid_background_function_metadata"
    assert result.text =~ "no valid target function metadata"

    assert [] ==
             BackgroundTask
             |> Ash.Query.filter(source_tool_call_item_id == ^source.item.id)
             |> Ash.read!(actor: actor)
  end

  test "snapshot forwards the cursor and persists a terminal result" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    runner = connect_runner!(tool_instance, "runner-progress", "session-progress")

    task_id =
      start_running_background!(actor, tool_instance, runner, "printf progress")

    first_check = Task.async(fn -> BackgroundTasks.snapshot(task_id, nil, actor.id) end)
    first_status = wait_for_control_call!(tool_instance, runner, "background_status")
    assert first_status.background_task_id == task_id
    refute Map.has_key?(first_status, :cursor)

    complete_background_call!(tool_instance, runner, first_status, %{
      "background_task_id" => task_id,
      "status" => "running",
      "progress" => [
        %{"cursor" => "1", "type" => "stdout", "text" => "first\n"}
      ],
      "next_cursor" => "1"
    })

    assert {:ok, first_snapshot} = Task.await(first_check, 5_000)
    assert first_snapshot["status"] == "running"
    assert first_snapshot["next_cursor"] == "1"

    assert first_snapshot["progress"] == [
             %{"cursor" => "1", "type" => "stdout", "text" => "first\n"}
           ]

    second_check = Task.async(fn -> BackgroundTasks.snapshot(task_id, "1", actor.id) end)
    second_status = wait_for_control_call!(tool_instance, runner, "background_status")
    assert second_status.background_task_id == task_id
    assert second_status.cursor == "1"

    result = %{
      "text" => "finished",
      "raw" => %{"exit_code" => 0},
      "media" => [%{"type" => "text", "text" => "media"}],
      "artifacts" => [%{"name" => "output.txt", "content" => "done"}]
    }

    complete_background_call!(tool_instance, runner, second_status, %{
      "background_task_id" => task_id,
      "status" => "completed",
      "progress" => [
        %{"cursor" => "2", "type" => "stdout", "text" => "done\n"}
      ],
      "next_cursor" => "2",
      "result" => result
    })

    assert {:ok, terminal_snapshot} = Task.await(second_check, 5_000)
    assert terminal_snapshot["status"] == "completed"
    assert terminal_snapshot["next_cursor"] == "2"

    assert terminal_snapshot["progress"] == [
             %{"cursor" => "2", "type" => "stdout", "text" => "done\n"}
           ]

    Runtime.reset!()

    assert {:ok, persisted_snapshot} = BackgroundTasks.snapshot(task_id, "2", actor.id)
    assert persisted_snapshot["status"] == "completed"
    assert persisted_snapshot["result"] == result
    assert persisted_snapshot["status_detail"] == "outlet_unavailable"
    assert persisted_snapshot["next_cursor"] == "2"
  end

  test "snapshot pages split progress and injects missing entry cursors" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    runner = connect_runner!(tool_instance, "runner-paged-progress", "session-paged-progress")

    task_id =
      start_running_background!(actor, tool_instance, runner, "printf paged-progress")

    chunk = String.duplicate("x", 12_000)
    first_check = Task.async(fn -> BackgroundTasks.snapshot(task_id, nil, actor.id) end)
    first_status = wait_for_control_call!(tool_instance, runner, "background_status")

    complete_background_call!(tool_instance, runner, first_status, %{
      "background_task_id" => task_id,
      "status" => "running",
      "progress" =>
        Enum.map(1..5, fn index ->
          %{"type" => "stdout", "text" => chunk <> Integer.to_string(index)}
        end),
      "next_cursor" => "5"
    })

    assert {:ok, first_snapshot} = Task.await(first_check, 5_000)
    assert first_snapshot["next_cursor"] == "3"
    assert Enum.map(first_snapshot["progress"], & &1["cursor"]) == ["1", "2", "3"]

    second_check = Task.async(fn -> BackgroundTasks.snapshot(task_id, "3", actor.id) end)
    second_status = wait_for_control_call!(tool_instance, runner, "background_status")
    assert second_status.cursor == "3"

    complete_background_call!(tool_instance, runner, second_status, %{
      "background_task_id" => task_id,
      "status" => "running",
      "progress" =>
        Enum.map(4..5, fn index ->
          %{"type" => "stdout", "text" => chunk <> Integer.to_string(index)}
        end),
      "next_cursor" => "5"
    })

    assert {:ok, second_snapshot} = Task.await(second_check, 5_000)
    assert second_snapshot["next_cursor"] == "5"
    assert Enum.map(second_snapshot["progress"], & &1["cursor"]) == ["4", "5"]
  end

  test "first check after durable completion still pages terminal outlet progress" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    runner =
      connect_runner!(tool_instance, "runner-terminal-progress", "session-terminal-progress")

    task_id = start_running_background!(actor, tool_instance, runner, "printf terminal")
    {:ok, task} = load_owned_task(task_id, actor.id)

    durable_result = %{
      "text" => "durable result",
      "raw" => %{"exit_code" => 0},
      "media" => [],
      "artifacts" => []
    }

    assert {:ok, %{status: :completed}} = BackgroundTasks.mark_completed(task, durable_result)

    check = Task.async(fn -> BackgroundTasks.snapshot(task_id, "0", actor.id) end)
    status_call = wait_for_control_call!(tool_instance, runner, "background_status")

    complete_background_call!(tool_instance, runner, status_call, %{
      "background_task_id" => task_id,
      "status" => "completed",
      "progress" => [
        %{"cursor" => "1", "type" => "stdout", "text" => "terminal chunk\n"}
      ],
      "next_cursor" => "1",
      "result" => %{"text" => "stale runner result", "raw" => %{}}
    })

    assert {:ok, snapshot} = Task.await(check, 5_000)
    assert snapshot["status"] == "completed"
    assert snapshot["result"] == durable_result
    assert snapshot["next_cursor"] == "1"

    assert snapshot["progress"] == [
             %{"cursor" => "1", "type" => "stdout", "text" => "terminal chunk\n"}
           ]
  end

  test "cancel preserves a runner completion that won the race" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    runner = connect_runner!(tool_instance, "runner-cancel-completed", "session-cancel-completed")

    task_id = start_running_background!(actor, tool_instance, runner, "echo completed")

    cancel = Task.async(fn -> BackgroundTasks.cancel(task_id, actor.id) end)
    cancel_call = wait_for_control_call!(tool_instance, runner, "background_cancel")

    result = %{
      "text" => "already completed",
      "raw" => %{"exit_code" => 0},
      "media" => [],
      "artifacts" => []
    }

    complete_background_call!(tool_instance, runner, cancel_call, %{
      "background_task_id" => task_id,
      "status" => "completed",
      "progress" => [],
      "next_cursor" => "0",
      "result" => result
    })

    terminal_status = wait_for_control_call!(tool_instance, runner, "background_status")

    complete_background_call!(tool_instance, runner, terminal_status, %{
      "background_task_id" => task_id,
      "status" => "completed",
      "progress" => [],
      "next_cursor" => "0",
      "result" => result
    })

    assert {:ok, snapshot} = Task.await(cancel, 5_000)
    assert snapshot["status"] == "completed"
    assert snapshot["cancel_requested"] == true
    assert snapshot["result"] == result
  end

  test "unbound outlet task reports local state and can be canceled without remote status" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    _runner = connect_runner!(tool_instance, "runner-unbound", "session-unbound")

    task = create_outlet_background_task!(actor, tool_instance, %{status: :running})

    assert {:ok, snapshot} = BackgroundTasks.snapshot(task.id, "opaque", actor.id)
    assert snapshot["status"] == "running"
    assert snapshot["status_detail"] == "outlet_starting"
    assert snapshot["progress"] == []
    assert snapshot["next_cursor"] == "opaque"

    assert {:ok, canceled} = BackgroundTasks.cancel(task.id, actor.id)
    assert canceled["status"] == "canceled"
  end

  test "checker fails an active outlet envelope after its tool instance is deleted" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    task =
      create_outlet_background_task!(actor, tool_instance, %{
        status: :running,
        runner_ref: %{
          "runner_id" => "deleted-runner",
          "runner_session_id" => "deleted-session",
          "start_acknowledged" => true
        }
      })

    assert :ok = Ash.destroy!(tool_instance, actor: actor)

    assert {:ok, snapshot} = BackgroundTasks.snapshot(task.id, nil, actor.id)
    assert snapshot["status"] == "failed"
    assert snapshot["error"]["code"] == "tool_instance_not_found"
    assert snapshot["error"]["outcome"] == "unknown"
  end

  test "expired runner tombstone fails the durable envelope without replay" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    runner = connect_runner!(tool_instance, "runner-expired", "session-expired")
    task_id = start_running_background!(actor, tool_instance, runner, "echo expired")

    check = Task.async(fn -> BackgroundTasks.snapshot(task_id, nil, actor.id) end)
    status_call = wait_for_control_call!(tool_instance, runner, "background_status")

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => status_call.call_id,
               "runner_id" => runner["runner_id"],
               "runner_session_id" => runner["runner_session_id"],
               "status" => "error",
               "error_text" =>
                 "outlet_task_expired: background task #{task_id} expired and cannot be restarted in this runner session"
             })

    assert {:ok, snapshot} = Task.await(check, 5_000)
    assert snapshot["status"] == "failed"
    assert snapshot["error"]["code"] == "outlet_task_expired"
    assert snapshot["error"]["outcome"] == "unknown"
  end

  test "status racing an unacknowledged start replays the start instead of failing the envelope" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    runner =
      connect_runner!(tool_instance, "runner-start-status-race", "session-start-status-race")

    task_id = launch_background!(actor, tool_instance, "echo race")

    wait_for_pending_operations!(tool_instance.id, ["background_start"])
    check = Task.async(fn -> BackgroundTasks.snapshot(task_id, nil, actor.id) end)

    wait_for_pending_operations!(tool_instance.id, ["background_start", "background_status"])

    assert {:ok, %{tasks: controls}} =
             Runtime.poll(
               tool_instance,
               Map.merge(runner, %{"control_capacity" => 2, "max_wait_seconds" => 0})
             )

    assert Enum.sort(Enum.map(controls, & &1.operation)) == [
             "background_start",
             "background_status"
           ]

    original_start = Enum.find(controls, &(&1.operation == "background_start"))
    early_status = Enum.find(controls, &(&1.operation == "background_status"))

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => early_status.call_id,
               "runner_id" => runner["runner_id"],
               "runner_session_id" => runner["runner_session_id"],
               "status" => "error",
               "error_text" => "background task not found: #{task_id}"
             })

    complete_background_call!(tool_instance, runner, original_start, %{
      "background_task_id" => task_id,
      "status" => "running",
      "progress" => [],
      "next_cursor" => "0"
    })

    replayed_start = wait_for_control_call!(tool_instance, runner, "background_start")
    assert replayed_start.call_id != original_start.call_id
    assert replayed_start.background_task_id == task_id
    assert replayed_start.arguments == %{"command" => "echo race"}

    complete_background_call!(tool_instance, runner, replayed_start, %{
      "background_task_id" => task_id,
      "status" => "running",
      "progress" => [],
      "next_cursor" => "0"
    })

    assert {:ok, snapshot} = Task.await(check, 5_000)
    assert snapshot["status"] == "running"
    refute snapshot["error"]

    wait_for_worker_exit(task_id)
    task = wait_for_task_status(task_id, actor.id, :running)
    assert task.runner_ref["start_acknowledged"] == true
  end

  test "live reaper turns an expired cancel into a terminal unknown failure" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    runner =
      connect_runner!(tool_instance, "runner-cancel-expired", "session-cancel-expired")

    task =
      create_outlet_background_task!(actor, tool_instance, %{
        status: :running,
        started_at: DateTime.utc_now(),
        runner_ref: %{
          "runner_id" => "runner-cancel-expired",
          "runner_session_id" => "session-cancel-expired",
          "start_acknowledged" => true
        }
      })
      |> request_cancel!(actor)

    sweep = Task.async(fn -> Reaper.sweep() end)

    cancel_call = wait_for_control_call!(tool_instance, runner, "background_cancel")

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => cancel_call.call_id,
               "runner_id" => runner["runner_id"],
               "runner_session_id" => runner["runner_session_id"],
               "status" => "error",
               "error_text" =>
                 "outlet_task_expired: background task #{task.id} expired and cannot be restarted in this runner session"
             })

    assert :ok = Task.await(sweep, 5_000)

    failed = wait_for_task_status(task.id, actor.id, :failed)
    assert failed.cancel_requested == true
    assert failed.error["code"] == "outlet_task_expired"
    assert failed.error["outcome"] == "unknown"
  end

  test "live reaper fails a canceled running task after its tool instance is deleted" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    task =
      create_outlet_background_task!(actor, tool_instance, %{
        status: :running,
        started_at: DateTime.utc_now(),
        runner_ref: %{
          "runner_id" => "deleted-cancel-runner",
          "runner_session_id" => "deleted-cancel-session",
          "start_acknowledged" => true
        }
      })
      |> request_cancel!(actor)

    assert :ok = Ash.destroy!(tool_instance, actor: actor)
    assert :ok = Reaper.sweep()

    assert {:ok, failed} = load_owned_task(task.id, actor.id)
    assert failed.status == :failed
    assert failed.cancel_requested == true
    assert failed.error["code"] == "tool_instance_not_found"
    assert failed.error["outcome"] == "unknown"
  end

  test "cancel propagates a failure to persist an expired terminal outcome" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    runner =
      connect_runner!(tool_instance, "runner-cancel-persist", "session-cancel-persist")

    persisted =
      create_outlet_background_task!(actor, tool_instance, %{
        status: :running,
        started_at: DateTime.utc_now(),
        runner_ref: %{
          "runner_id" => "runner-cancel-persist",
          "runner_session_id" => "session-cancel-persist",
          "start_acknowledged" => true
        }
      })

    missing = %{persisted | id: Ecto.UUID.generate()}
    cancel = Task.async(fn -> Outlet.cancel_background(missing) end)
    cancel_call = wait_for_control_call!(tool_instance, runner, "background_cancel")

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => cancel_call.call_id,
               "runner_id" => runner["runner_id"],
               "runner_session_id" => runner["runner_session_id"],
               "status" => "error",
               "error_text" =>
                 "outlet_task_expired: background task #{missing.id} expired and cannot be restarted in this runner session"
             })

    assert {:error, :not_found} = Task.await(cancel, 5_000)
  end

  test "reconnect fails an acknowledged cancel when the runner lost the task" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    task =
      create_outlet_background_task!(actor, tool_instance, %{
        status: :running,
        started_at: DateTime.utc_now(),
        runner_ref: %{
          "runner_id" => "runner-cancel-missing",
          "runner_session_id" => "session-cancel-missing",
          "start_acknowledged" => true
        }
      })
      |> request_cancel!(actor)

    runner =
      connect_runner!(tool_instance, "runner-cancel-missing", "session-cancel-missing")

    cancel_call = wait_for_control_call!(tool_instance, runner, "background_cancel")

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => cancel_call.call_id,
               "runner_id" => runner["runner_id"],
               "runner_session_id" => runner["runner_session_id"],
               "status" => "error",
               "error_text" => "background task not found: #{task.id}"
             })

    failed = wait_for_task_status(task.id, actor.id, :failed)
    assert failed.cancel_requested == true
    assert failed.error["code"] == "outlet_task_not_found"
    assert failed.error["outcome"] == "unknown"
  end

  test "queued unacknowledged cancel treats runner task_not_found as safe cancellation" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)

    task =
      create_outlet_background_task!(actor, tool_instance, %{
        status: :queued,
        runner_ref: %{
          "runner_id" => "runner-cancel-before-start",
          "runner_session_id" => "session-cancel-before-start"
        }
      })
      |> request_cancel!(actor)

    runner =
      connect_runner!(
        tool_instance,
        "runner-cancel-before-start",
        "session-cancel-before-start"
      )

    cancel_call = wait_for_control_call!(tool_instance, runner, "background_cancel")

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => cancel_call.call_id,
               "runner_id" => runner["runner_id"],
               "runner_session_id" => runner["runner_session_id"],
               "status" => "error",
               "error_text" => "background task not found: #{task.id}"
             })

    canceled = wait_for_task_status(task.id, actor.id, :canceled)
    assert canceled.cancel_requested == true
    refute canceled.error
  end

  test "reconnecting the same runner session replays background_start with the same UUID" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    _runner = connect_runner!(tool_instance, "runner-replay", "session-replay")

    task =
      create_outlet_background_task!(actor, tool_instance, %{
        status: :running,
        started_at: DateTime.utc_now(),
        runner_ref: %{
          "runner_id" => "runner-replay",
          "runner_session_id" => "session-replay"
        }
      })

    Runtime.reset!()
    reconnected = connect_runner!(tool_instance, "runner-replay", "session-replay")

    replay = wait_for_control_call!(tool_instance, reconnected, "background_start")
    assert replay.background_task_id == task.id
    assert replay.function == "run_command"
    assert replay.arguments == task.arguments

    complete_background_call!(tool_instance, reconnected, replay, %{
      "background_task_id" => task.id,
      "status" => "completed",
      "progress" => [],
      "next_cursor" => "0",
      "result" => %{"text" => "replayed", "raw" => %{}, "media" => [], "artifacts" => []}
    })

    completed = wait_for_task_status(task.id, actor.id, :completed)
    assert completed.result["text"] == "replayed"
  end

  test "reconnecting with a new runner session fails the task with an unknown outcome" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    runner = connect_runner!(tool_instance, "runner-replaced", "session-original")

    task_id = start_running_background!(actor, tool_instance, runner, "echo replaced")

    Runtime.reset!()
    _reconnected = connect_runner!(tool_instance, "runner-replaced", "session-new")

    task = wait_for_task_status(task_id, actor.id, :failed)
    assert task.error["code"] == "outlet_runner_restarted"
    assert task.error["outcome"] == "unknown"

    assert {:ok, snapshot} = BackgroundTasks.snapshot(task_id, nil, actor.id)
    assert snapshot["status"] == "failed"
    assert snapshot["error"]["code"] == "outlet_runner_restarted"
    assert snapshot["error"]["outcome"] == "unknown"
  end

  test "offline cancel remains requested until reconnect acknowledges background_cancel" do
    %{user: actor} = user_fixture()
    tool_instance = create_outlet_tool_instance!(actor)
    runner = connect_runner!(tool_instance, "runner-cancel", "session-cancel")

    task_id = start_running_background!(actor, tool_instance, runner, "sleep forever")

    Runtime.reset!()

    assert {:ok, requested_snapshot} = BackgroundTasks.cancel(task_id, actor.id)
    assert requested_snapshot["status"] == "running"
    assert requested_snapshot["cancel_requested"] == true

    requested = wait_for_task_status(task_id, actor.id, :running)
    assert requested.cancel_requested == true

    reconnected = connect_runner!(tool_instance, "runner-cancel", "session-cancel")
    cancel_call = wait_for_control_call!(tool_instance, reconnected, "background_cancel")

    assert cancel_call.background_task_id == task_id
    assert cancel_call.cursor == "0"

    complete_background_call!(tool_instance, reconnected, cancel_call, %{
      "background_task_id" => task_id,
      "status" => "canceled",
      "progress" => [],
      "next_cursor" => "0"
    })

    canceled = wait_for_task_status(task_id, actor.id, :canceled)
    assert canceled.cancel_requested == true

    assert {:ok, canceled_snapshot} = BackgroundTasks.snapshot(task_id, nil, actor.id)
    assert canceled_snapshot["status"] == "canceled"
    assert canceled_snapshot["cancel_requested"] == true
  end

  defp start_running_background!(actor, tool_instance, runner, command) do
    task_id = launch_background!(actor, tool_instance, command)
    start_call = wait_for_control_call!(tool_instance, runner, "background_start")

    assert start_call.background_task_id == task_id

    complete_background_call!(tool_instance, runner, start_call, %{
      "background_task_id" => task_id,
      "status" => "running",
      "progress" => [],
      "next_cursor" => "0"
    })

    wait_for_worker_exit(task_id)
    _task = wait_for_task_status(task_id, actor.id, :running)
    task_id
  end

  defp launch_background!(actor, tool_instance, command) do
    source = create_source_tool_call!(actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.chat.id,
      message_id: source.message.id,
      assistant_message_id: source.message.id,
      step_id: source.step.id,
      tool_call_item_id: source.item.id,
      available_file_external_ids: []
    }

    assert {:ok, launch} =
             BackgroundTasks.start_tool(
               tool_instance,
               "run_command",
               %{"command" => command},
               context
             )

    task_id = launch.raw["background_task_id"]
    assert Ecto.UUID.cast(task_id) == {:ok, task_id}
    task_id
  end

  defp connect_runner!(tool_instance, runner_id, runner_session_id) do
    discovery_runner = %{
      "runner_id" => runner_id,
      "runner_session_id" => runner_session_id,
      "capacity" => 1,
      "control_capacity" => 0,
      "max_wait_seconds" => 0
    }

    assert {:ok, %{status: "ok", tasks: [discovery]}} =
             Runtime.poll(tool_instance, discovery_runner)

    assert discovery.operation == "execute"
    assert discovery.function == "outlet.list_tools"

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => discovery.call_id,
               "runner_id" => runner_id,
               "runner_session_id" => runner_session_id,
               "status" => "done",
               "result_raw" => %{"tools" => []}
             })

    %{discovery_runner | "capacity" => 0, "control_capacity" => 1}
  end

  defp wait_for_control_call!(tool_instance, runner, operation, attempts \\ 250)

  defp wait_for_control_call!(tool_instance, _runner, operation, 0) do
    runtime =
      Runtime
      |> :sys.get_state()
      |> get_in([:instances, tool_instance.id])
      |> case do
        %{} = instance -> Map.take(instance, [:runner, :pending, :running])
        other -> other
      end

    tasks =
      BackgroundTask
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.tool_instance_id == tool_instance.id))
      |> Enum.map(&Map.take(&1, [:id, :status, :runner_ref, :cancel_requested, :error]))

    flunk(
      "Timed out waiting for #{operation}; runtime=#{inspect(runtime)} tasks=#{inspect(tasks)}"
    )
  end

  defp wait_for_control_call!(tool_instance, runner, operation, attempts) do
    case Runtime.poll(tool_instance, runner) do
      {:ok, %{tasks: tasks}} ->
        case Enum.find(tasks, &(&1.operation == operation)) do
          nil ->
            if tasks == [] do
              Process.sleep(20)
              wait_for_control_call!(tool_instance, runner, operation, attempts - 1)
            else
              flunk("Expected #{operation}, got #{inspect(Enum.map(tasks, & &1.operation))}")
            end

          call ->
            call
        end

      other ->
        flunk("Unexpected outlet poll result: #{inspect(other)}")
    end
  end

  defp complete_background_call!(tool_instance, runner, call, result_raw) do
    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => call.call_id,
               "runner_id" => runner["runner_id"],
               "runner_session_id" => runner["runner_session_id"],
               "status" => "done",
               "result_raw" => result_raw
             })
  end

  defp wait_for_task_status(task_id, owner_id, status, attempts \\ 250)

  defp wait_for_task_status(task_id, owner_id, status, 0) do
    current = load_owned_task(task_id, owner_id)
    flunk("Background task did not reach #{status}: #{inspect(current)}")
  end

  defp wait_for_task_status(task_id, owner_id, status, attempts) do
    case load_owned_task(task_id, owner_id) do
      {:ok, %{status: ^status} = task} ->
        task

      {:ok, _task} ->
        Process.sleep(20)
        wait_for_task_status(task_id, owner_id, status, attempts - 1)

      other ->
        flunk("Unable to load background task: #{inspect(other)}")
    end
  end

  defp load_owned_task(task_id, owner_id) do
    case Ash.get(BackgroundTask, task_id, actor: %User{id: owner_id}) do
      {:ok, %BackgroundTask{} = task} -> {:ok, task}
      _other -> {:error, :not_found}
    end
  end

  defp wait_for_worker_exit(task_id, attempts \\ 250)

  defp wait_for_worker_exit(task_id, 0) do
    flunk("Background worker #{task_id} did not stop")
  end

  defp wait_for_worker_exit(task_id, attempts) do
    case Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task_id) do
      [] ->
        :ok

      _workers ->
        Process.sleep(20)
        wait_for_worker_exit(task_id, attempts - 1)
    end
  end

  defp wait_for_pending_operations!(tool_instance_id, expected, attempts \\ 250)

  defp wait_for_pending_operations!(_tool_instance_id, expected, 0) do
    flunk("Timed out waiting for pending outlet operations: #{inspect(expected)}")
  end

  defp wait_for_pending_operations!(tool_instance_id, expected, attempts) do
    operations =
      Runtime
      |> :sys.get_state()
      |> get_in([:instances, tool_instance_id, :pending])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, :operation, "execute"))

    available = Enum.frequencies(operations)

    ready? =
      expected
      |> Enum.frequencies()
      |> Enum.all?(fn {operation, count} -> Map.get(available, operation, 0) >= count end)

    if ready? do
      :ok
    else
      Process.sleep(20)
      wait_for_pending_operations!(tool_instance_id, expected, attempts - 1)
    end
  end

  defp ensure_outlet_runtime_started do
    if Process.whereis(IntellectualClub.Outlets.Runtime) do
      :ok
    else
      case Supervisor.restart_child(
             IntellectualClub.Supervisor,
             IntellectualClub.Outlets.Runtime
           ) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp request_cancel!(%BackgroundTask{} = task, actor) do
    task
    |> Ash.Changeset.for_update(:update_state, %{cancel_requested: true}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp create_source_tool_call!(actor) do
    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Run", actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step_id = Persistence.ensure_step_started!(message.id, 1, %{}, [])
    step = Ash.get!(ChatMessageStep, step_id, actor: actor)

    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 1, type: :tool_call},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    %{chat: chat, message: message, step: step, item: item}
  end

  defp create_outlet_background_task!(actor, tool_instance, attrs) do
    source = create_source_tool_call!(actor)

    base = %{
      kind: "outlet_function",
      adapter: "outlet",
      status: :queued,
      function_name: "run_command",
      arguments: %{"command" => "echo recovered"},
      execution_context: %{
        "owner_id" => actor.id,
        "chat_id" => source.chat.id,
        "message_id" => source.message.id,
        "assistant_message_id" => source.message.id,
        "step_id" => source.step.id,
        "tool_call_item_id" => source.item.id,
        "available_file_external_ids" => []
      },
      runner_ref: %{},
      tool_instance_id: tool_instance.id,
      source_chat_id: source.chat.id,
      source_message_id: source.message.id,
      source_step_id: source.step.id,
      source_tool_call_item_id: source.item.id
    }

    BackgroundTask
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_outlet_tool_instance!(actor) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "outlet",
        name: "Background Outlet",
        alias: "outlet",
        config: %{
          "max_concurrency" => 1,
          "poll_max_wait_seconds" => 0,
          "runner_online_timeout_seconds" => 60,
          "disconnect_grace_seconds" => 300
        },
        secrets: %{"token" => "background-outlet-token"},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
