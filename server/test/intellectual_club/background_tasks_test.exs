defmodule IntellectualClub.BackgroundTasksTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.BackgroundTasks.Reaper
  alias IntellectualClub.BackgroundTasks.Supervisor, as: TaskSupervisor
  alias IntellectualClub.BackgroundTasks.Worker
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Tools.Drivers.Ssh
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  test "start_tool is idempotent for a persisted source tool call" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    tool_instance = create_ssh_tool_instance!(actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.chat.id,
      message_id: source.message.id,
      assistant_message_id: source.message.id,
      step_id: source.step.id,
      tool_call_item_id: source.item.id,
      available_file_external_ids: []
    }

    assert {:ok, first} =
             BackgroundTasks.start_tool(
               tool_instance,
               "run_command",
               %{"command" => "echo background"},
               context
             )

    assert {:ok, second} =
             BackgroundTasks.start_tool(
               tool_instance,
               "run_command",
               %{"command" => "echo background"},
               context
             )

    task_id = first.raw["background_task_id"]
    assert Ecto.UUID.cast(task_id) == {:ok, task_id}
    assert second.raw["background_task_id"] == task_id

    tasks =
      BackgroundTask
      |> Ash.Query.filter(source_tool_call_item_id == ^source.item.id)
      |> Ash.read!(actor: actor)

    assert Enum.map(tasks, & &1.id) == [task_id]
    assert wait_for_terminal_status(task_id, actor.id) in ["failed", "canceled"]
  end

  test "background launch fails closed without a persisted source tool call" do
    %{user: actor} = user_fixture()
    tool_instance = create_ssh_tool_instance!(actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      available_file_external_ids: []
    }

    assert {:error, "Background task launch requires a persisted source tool call."} =
             BackgroundTasks.start_tool(
               tool_instance,
               "run_command",
               %{"command" => "echo must-not-run"},
               context
             )

    assert [] ==
             BackgroundTask
             |> Ash.Query.filter(owner_id == ^actor.id)
             |> Ash.read!(actor: actor)
  end

  test "background launch rejects a stale parent generation epoch without creating a task" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    tool_instance = create_ssh_tool_instance!(actor)

    assert {:ok, lease} = Lease.acquire(source.message.id)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.chat.id,
      message_id: source.message.id,
      assistant_message_id: source.message.id,
      step_id: source.step.id,
      generation_fence_token: lease.fence_token,
      tool_call_item_id: source.item.id,
      available_file_external_ids: []
    }

    assert :canceled =
             Persistence.cancel_generating_message!(source.message.id,
               error_detail: nil
             )

    assert :ok = Lease.release(lease)

    assert {:error, :parent_generation_stale} =
             BackgroundTasks.start_tool(
               tool_instance,
               "run_command",
               %{"command" => "echo must-not-run"},
               context
             )

    assert [] ==
             BackgroundTask
             |> Ash.Query.filter(source_tool_call_item_id == ^source.item.id)
             |> Ash.read!(actor: actor)
  end

  test "background launch rejects a completed parent even while its old epoch is retained" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    tool_instance = create_ssh_tool_instance!(actor)

    assert {:ok, lease} = Lease.acquire(source.message.id)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.chat.id,
      message_id: source.message.id,
      assistant_message_id: source.message.id,
      step_id: source.step.id,
      generation_fence_token: lease.fence_token,
      tool_call_item_id: source.item.id,
      available_file_external_ids: []
    }

    _completed =
      source.message
      |> Ash.Changeset.for_update(
        :set_generation_state,
        %{status: :done, finished_at: DateTime.utc_now()},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert :ok = Lease.release(lease)

    assert {:error, :parent_generation_stale} =
             BackgroundTasks.start_tool(
               tool_instance,
               "run_command",
               %{"command" => "echo must-not-run"},
               context
             )

    assert [] ==
             BackgroundTask
             |> Ash.Query.filter(source_tool_call_item_id == ^source.item.id)
             |> Ash.read!(actor: actor)
  end

  test "source lifecycle cancellation marks only active tasks" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    unrelated_source = create_source_tool_call!(actor)

    queued =
      create_background_task!(
        actor,
        source
        |> source_message_attrs(actor)
        |> Map.put(:status, :queued)
      )

    running =
      create_background_task!(
        actor,
        source
        |> source_message_attrs(actor)
        |> Map.merge(%{status: :running, started_at: DateTime.utc_now()})
      )

    completed =
      create_background_task!(actor, source_message_attrs(source, actor))
      |> then(fn task ->
        assert {:ok, completed} = BackgroundTasks.mark_completed(task, %{text: "done"})
        completed
      end)

    unrelated =
      create_background_task!(actor, source_message_attrs(unrelated_source, actor))

    requested_ids = BackgroundTasks.request_cancel_for_source_message!(source.message.id)

    assert MapSet.new(requested_ids) == MapSet.new([queued.id, running.id])

    assert {:ok, %{status: :queued, cancel_requested: true}} =
             BackgroundTasks.fetch_internal(queued.id)

    assert {:ok, %{status: :running, cancel_requested: true}} =
             BackgroundTasks.fetch_internal(running.id)

    assert {:ok, %{status: :completed, cancel_requested: false}} =
             BackgroundTasks.fetch_internal(completed.id)

    assert {:ok, %{status: :queued, cancel_requested: false}} =
             BackgroundTasks.fetch_internal(unrelated.id)
  end

  test "claim fails closed after the source generation becomes terminal" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    task = create_background_task!(actor, source_message_attrs(source, actor))

    _done =
      source.message
      |> Ash.Changeset.for_update(
        :set_generation_state,
        %{status: :done, finished_at: DateTime.utc_now()},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert {:ok, canceled} = BackgroundTasks.mark_running(task)
    assert canceled.status == :canceled
    assert canceled.cancel_requested == true
    assert canceled.started_at == nil
  end

  test "execution context is rebuilt from its persisted JSON shape" do
    %{user: actor} = user_fixture()
    created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    generation_fence_token = Ecto.UUID.generate()

    task =
      create_background_task!(actor, %{
        execution_context: %{
          "owner_id" => actor.id,
          "chat_id" => 101,
          "message_id" => 102,
          "assistant_message_id" => 103,
          "step_id" => 104,
          "generation_fence_token" => generation_fence_token,
          "provider_type" => "responses",
          "available_file_external_ids" => ["file-1"],
          "tool_call_item_id" => 105,
          "tool_call_created_at" => DateTime.to_iso8601(created_at)
        }
      })

    assert %ExecutionContext{} = context = BackgroundTasks.execution_context(task)
    assert context.owner_id == actor.id
    assert context.chat_id == 101
    assert context.message_id == 102
    assert context.assistant_message_id == 103
    assert context.step_id == 104
    assert context.generation_fence_token == generation_fence_token
    assert context.provider_type == "responses"
    assert context.available_file_external_ids == ["file-1"]
    assert context.tool_call_item_id == 105
    assert context.tool_call_created_at == created_at
  end

  test "fork references use the internal atom-key contract before persistence" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    task = create_background_task!(actor, %{})

    assert {:ok, updated} =
             BackgroundTasks.set_fork_reference(task, %{
               chat_id: source.chat.id,
               message_id: source.message.id,
               generation_message_id: source.message.id,
               url: "/chats/#{source.chat.id}"
             })

    assert updated.target_chat_id == source.chat.id
    assert updated.runner_ref["fork_chat_id"] == source.chat.id
    assert updated.runner_ref["fork_message_id"] == source.message.id
    assert updated.runner_ref["fork_generation_message_id"] == source.message.id
    assert updated.runner_ref["fork_url"] == "/chats/#{source.chat.id}"
  end

  test "snapshot returns stdout and stderr incrementally by cursor and enforces ownership" do
    %{user: actor} = user_fixture()
    %{user: other_actor} = user_fixture()
    task = create_background_task!(actor, %{status: :running, started_at: DateTime.utc_now()})

    assert {:ok, first_event} = BackgroundTasks.append_event(task, :stdout, "one\n")
    assert {:ok, second_event} = BackgroundTasks.append_event(task, :stderr, "two\n")

    assert {:ok, first_snapshot} = BackgroundTasks.snapshot(task.id, nil, actor.id)

    assert first_snapshot["progress"] == [
             %{
               "cursor" => Integer.to_string(first_event.id),
               "type" => "stdout",
               "text" => "one\n"
             },
             %{
               "cursor" => Integer.to_string(second_event.id),
               "type" => "stderr",
               "text" => "two\n"
             }
           ]

    assert first_snapshot["next_cursor"] == Integer.to_string(second_event.id)

    assert {:ok, second_snapshot} =
             BackgroundTasks.snapshot(task.id, Integer.to_string(first_event.id), actor.id)

    assert Enum.map(second_snapshot["progress"], & &1["text"]) == ["two\n"]
    assert {:error, :not_found} = BackgroundTasks.snapshot(task.id, nil, other_actor.id)
  end

  test "live reaper fails a running SSH task as execution_lost without rerunning it" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)

    task =
      create_background_task!(
        actor,
        source
        |> source_message_attrs(actor)
        |> Map.merge(%{
          status: :running,
          started_at: DateTime.utc_now(),
          arguments: %{"command" => "non-idempotent-command"}
        })
      )

    test_pid = self()

    :ok =
      Ssh.register_background_cancel_ref(task.id, :connection_ref, 42, fn refs ->
        send(test_pid, {:lost_ssh_refs_closed, refs})
      end)

    assert :ok = Reaper.sweep()
    assert_receive {:lost_ssh_refs_closed, %{connection: :connection_ref, channel: 42}}
    assert {:ok, snapshot} = BackgroundTasks.snapshot(task.id, nil, actor.id)
    assert snapshot["status"] == "failed"
    assert snapshot["error"]["code"] == "execution_lost"
    assert snapshot["error"]["outcome"] == "unknown"
    assert snapshot["runner_ref"]["remote_termination_confirmed"] == false
    assert Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id) == []

    assert :ok = Reaper.sweep()
    refute_receive {:lost_ssh_refs_closed, _refs}
  end

  test "live reaper finishes a detached explicit SSH cancellation instead of execution_lost" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now(),
        runner_ref: %{"remote_pid" => "1234"}
      })

    assert :ok = Reaper.sweep()
    assert {:ok, snapshot} = BackgroundTasks.snapshot(task.id, nil, actor.id)
    assert snapshot["status"] == "canceled"
    assert snapshot["cancel_requested"] == true
    assert snapshot["error"] == nil
    assert snapshot["runner_ref"]["remote_termination_confirmed"] == false
  end

  test "live reaper retries a queued task after the worker supervisor returns" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    tool_instance = create_ssh_tool_instance!(actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.chat.id,
      message_id: source.message.id,
      assistant_message_id: source.message.id,
      step_id: source.step.id,
      tool_call_item_id: source.item.id,
      available_file_external_ids: []
    }

    assert :ok =
             Supervisor.terminate_child(
               IntellectualClub.Supervisor,
               IntellectualClub.BackgroundTasks.Supervisor
             )

    on_exit(fn -> ensure_background_worker_supervisor_started() end)

    assert {:ok, launch} =
             BackgroundTasks.start_tool(
               tool_instance,
               "run_command",
               %{"command" => "echo after supervisor restart"},
               context
             )

    task_id = launch.raw["background_task_id"]
    assert {:ok, %{status: :queued}} = BackgroundTasks.fetch_internal(task_id)

    reaper = start_supervised!({Reaper, name: nil, enabled: true, interval_ms: 25})

    assert :ok =
             wait_for_condition(fn ->
               :sys.get_state(reaper).failure_count > 0
             end)

    assert {:ok, %{status: :queued}} = BackgroundTasks.fetch_internal(task_id)

    assert {:ok, _pid} =
             Supervisor.restart_child(
               IntellectualClub.Supervisor,
               IntellectualClub.BackgroundTasks.Supervisor
             )

    assert wait_for_terminal_status(task_id, actor.id) == "failed"
  end

  test "live reaper does not duplicate an already active worker" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    task = create_background_task!(actor, source_message_attrs(source, actor))
    execution_supervisor = IntellectualClub.BackgroundTasks.ExecutionSupervisor

    :ok = :sys.suspend(execution_supervisor)

    on_exit(fn ->
      case Process.whereis(execution_supervisor) do
        pid when is_pid(pid) -> _ = :sys.resume(pid)
        _other -> :ok
      end
    end)

    assert :ok = Reaper.sweep()
    [{worker_pid, _value}] = wait_for_worker(task.id)
    assert Process.alive?(worker_pid)

    assert :ok = Reaper.sweep()

    assert Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id) == [
             {worker_pid, nil}
           ]

    assert %{active: 1} = DynamicSupervisor.count_children(TaskSupervisor)

    :ok = :sys.resume(execution_supervisor)
    assert wait_for_terminal_status(task.id, actor.id) == "failed"
  end

  test "live reaper cancels a task with a terminal source even when its worker is alive" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    task = create_background_task!(actor, source_message_attrs(source, actor))
    execution_supervisor = IntellectualClub.BackgroundTasks.ExecutionSupervisor

    :ok = :sys.suspend(execution_supervisor)

    on_exit(fn ->
      case Process.whereis(execution_supervisor) do
        pid when is_pid(pid) -> _ = :sys.resume(pid)
        _other -> :ok
      end
    end)

    assert :ok = Reaper.sweep()
    [{worker_pid, _value}] = wait_for_worker(task.id)
    assert Process.alive?(worker_pid)

    _done =
      source.message
      |> Ash.Changeset.for_update(
        :set_generation_state,
        %{status: :done, finished_at: DateTime.utc_now()},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert [task_id] = BackgroundTasks.request_cancel_for_source_message!(source.message.id)
    assert task_id == task.id

    reaper = Task.async(fn -> Reaper.sweep() end)
    :ok = :sys.resume(execution_supervisor)
    assert :ok = Task.await(reaper, 12_000)
    assert wait_for_terminal_status(task.id, actor.id) == "canceled"
    assert Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id) == []
  end

  test "live reaper cancels active tasks whose source is missing" do
    %{user: actor} = user_fixture()
    task = create_background_task!(actor, %{status: :queued})

    assert :ok = Reaper.sweep()
    assert {:ok, snapshot} = BackgroundTasks.snapshot(task.id, nil, actor.id)
    assert snapshot["status"] == "canceled"
    assert snapshot["cancel_requested"] == true
    assert Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id) == []
  end

  test "a waiter execution_lost result cannot beat a durable cancel request" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now()
      })

    execution_task = detached_waiting_task()

    state = %Worker{
      task_id: task.id,
      task: task,
      execution_task: execution_task
    }

    assert {:stop, :normal, %Worker{}} =
             Worker.handle_info(
               {execution_task.ref,
                {:failed,
                 %{
                   "code" => "execution_lost",
                   "message" => "SSH channel closed during cancel.",
                   "outcome" => "unknown"
                 }}},
               state
             )

    Process.exit(execution_task.pid, :kill)

    assert {:ok, %{status: :canceled, error: nil}} = BackgroundTasks.fetch_internal(task.id)
  end

  test "a successful waiter result that won before cancel remains completed" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now()
      })

    execution_task = detached_waiting_task()

    state = %Worker{
      task_id: task.id,
      task: task,
      execution_task: execution_task
    }

    result = %ExecutionResult{text: "already done", raw: %{"exit_code" => 0}}

    assert {:stop, :normal, %Worker{}} =
             Worker.handle_info({execution_task.ref, {:ok, result}}, state)

    Process.exit(execution_task.pid, :kill)

    assert {:ok, completed} = BackgroundTasks.fetch_internal(task.id)
    assert completed.status == :completed
    assert completed.result["text"] == "already done"
    assert completed.cancel_requested == true
  end

  test "a successful result pending durable persistence survives a later cancel" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now()
      })

    result = %ExecutionResult{text: "persist me", raw: %{"exit_code" => 0}}
    reply_tag = make_ref()

    state = %Worker{
      task_id: task.id,
      task: task,
      pending_result: {:ok, result}
    }

    assert {:stop, :normal, %Worker{pending_result: nil}} =
             Worker.handle_call(:cancel, {self(), reply_tag}, state)

    assert_receive {^reply_tag, :ok}

    assert {:ok, completed} = BackgroundTasks.fetch_internal(task.id)
    assert completed.status == :completed
    assert completed.result["text"] == "persist me"
    assert completed.cancel_requested == true
  end

  test "a pending successful result survives an adapter cancel error" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        adapter: "outlet",
        kind: "outlet_function",
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now(),
        runner_ref: %{
          "runner_id" => "missing-runner",
          "runner_session_id" => "missing-session"
        }
      })

    result = %ExecutionResult{text: "completed first", raw: %{"exit_code" => 0}}
    reply_tag = make_ref()

    state = %Worker{
      task_id: task.id,
      task: task,
      pending_result: {:ok, result}
    }

    assert {:stop, :normal, %Worker{pending_result: nil}} =
             Worker.handle_call(:cancel, {self(), reply_tag}, state)

    assert_receive {^reply_tag, :ok}

    assert {:ok, completed} = BackgroundTasks.fetch_internal(task.id)
    assert completed.status == :completed
    assert completed.result["text"] == "completed first"
    assert completed.cancel_requested == true
  end

  test "terminal completion cannot transition to failed or canceled" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, completed} =
             BackgroundTasks.mark_completed(task, %{
               text: "done",
               raw: %{"value" => 42}
             })

    assert completed.status == :completed
    assert {:ok, after_failure} = BackgroundTasks.mark_failed(task, "late_failure", "too late")
    assert after_failure.status == :completed
    assert {:ok, after_cancel} = BackgroundTasks.mark_canceled(task)
    assert after_cancel.status == :completed

    assert {:ok, snapshot} = BackgroundTasks.snapshot(task.id, nil, actor.id)
    assert snapshot["status"] == "completed"
    assert snapshot["cancel_requested"] == false
    assert snapshot["result"]["text"] == "done"
    assert snapshot["result"]["raw"] == %{"value" => 42}
    assert snapshot["error"] == nil
  end

  test "canceling a queued task does not start its worker" do
    %{user: actor} = user_fixture()
    task = create_background_task!(actor, %{status: :queued})

    assert Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id) == []
    assert {:ok, canceled} = BackgroundTasks.cancel(task.id, actor.id)
    assert canceled["status"] == "canceled"
    assert canceled["progress"] == []
    assert Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id) == []

    assert :ok = BackgroundTasks.recover()
    assert Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id) == []
    assert {:ok, recovered} = BackgroundTasks.snapshot(task.id, nil, actor.id)
    assert recovered["status"] == "canceled"
  end

  test "repeated launch payload for the same source tool call creates one task" do
    %{user: actor} = user_fixture()
    source = create_source_tool_call!(actor)
    tool_instance = create_ssh_tool_instance!(actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.chat.id,
      message_id: source.message.id,
      assistant_message_id: source.message.id,
      step_id: source.step.id,
      tool_call_item_id: source.item.id,
      available_file_external_ids: []
    }

    payload = %{"command" => "echo once", "timeout_seconds" => 1}

    assert {:ok, first} =
             BackgroundTasks.start_tool(tool_instance, "run_command", payload, context)

    assert {:ok, repeated} =
             BackgroundTasks.start_tool(tool_instance, "run_command", payload, context)

    assert repeated.raw["background_task_id"] == first.raw["background_task_id"]

    tasks =
      BackgroundTask
      |> Ash.Query.filter(source_tool_call_item_id == ^source.item.id)
      |> Ash.read!(actor: actor)

    assert [%BackgroundTask{id: task_id, arguments: ^payload}] = tasks
    assert task_id == first.raw["background_task_id"]
    assert wait_for_terminal_status(task_id, actor.id) in ["failed", "canceled"]
  end

  test "cancel hides a task UUID from another owner" do
    %{user: actor} = user_fixture()
    %{user: other_actor} = user_fixture()
    task = create_background_task!(actor, %{status: :queued})

    assert {:error, :not_found} = BackgroundTasks.cancel(task.id, other_actor.id)
    assert {:ok, snapshot} = BackgroundTasks.snapshot(task.id, nil, actor.id)
    assert snapshot["status"] == "queued"
    assert snapshot["cancel_requested"] == false
  end

  test "canceling an SSH task records unconfirmed remote termination" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        status: :running,
        started_at: DateTime.utc_now(),
        runner_ref: %{"remote_pid" => "1234"}
      })

    test_pid = self()

    :ok =
      Ssh.register_background_cancel_ref(task.id, :connection_ref, 42, fn refs ->
        send(test_pid, {:ssh_refs_closed, refs})
      end)

    assert {:ok, snapshot} = BackgroundTasks.cancel(task.id, actor.id)
    assert_receive {:ssh_refs_closed, %{connection: :connection_ref, channel: 42}}
    assert snapshot["status"] == "canceled"
    assert snapshot["cancel_requested"] == true
    assert snapshot["runner_ref"]["remote_pid"] == "1234"
    assert snapshot["runner_ref"]["remote_termination_confirmed"] == false
  end

  defp create_background_task!(actor, attrs) do
    {cancel_requested, attrs} = Map.pop(attrs, :cancel_requested, false)

    base = %{
      kind: "ssh_command",
      adapter: "ssh",
      status: :queued,
      function_name: "run_command",
      arguments: %{"command" => "echo test"},
      execution_context: %{"owner_id" => actor.id},
      runner_ref: %{}
    }

    task =
      BackgroundTask
      |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), actor: actor)
      |> Ash.create!(actor: actor)

    if cancel_requested do
      task
      |> Ash.Changeset.for_update(:update_state, %{cancel_requested: true}, actor: actor)
      |> Ash.update!(actor: actor)
    else
      task
    end
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

  defp source_message_attrs(source, actor) do
    %{
      source_chat_id: source.chat.id,
      source_message_id: source.message.id,
      execution_context: %{
        "owner_id" => actor.id,
        "chat_id" => source.chat.id,
        "message_id" => source.message.id,
        "assistant_message_id" => source.message.id
      }
    }
  end

  defp create_ssh_tool_instance!(actor) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "ssh",
        name: "Background SSH",
        alias: "ssh",
        config: %{
          "host" => "127.0.0.1",
          "port" => 1,
          "username" => "nobody",
          "connect_timeout_seconds" => 0,
          "default_timeout_seconds" => 1
        },
        secrets: %{"password" => "not-used"},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp wait_for_terminal_status(task_id, owner_id, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_terminal_status(task_id, owner_id, deadline)
  end

  defp do_wait_for_terminal_status(task_id, owner_id, deadline) do
    {:ok, snapshot} = BackgroundTasks.snapshot(task_id, nil, owner_id)

    if snapshot["status"] in ["completed", "failed", "canceled"] do
      snapshot["status"]
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_terminal_status(task_id, owner_id, deadline)
      else
        flunk("Background task #{task_id} did not reach a terminal status")
      end
    end
  end

  defp wait_for_worker(task_id, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_worker(task_id, deadline)
  end

  defp wait_for_condition(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_condition(fun, deadline)
  end

  defp do_wait_for_condition(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_wait_for_condition(fun, deadline)
      else
        flunk("condition was not satisfied before timeout")
      end
    end
  end

  defp do_wait_for_worker(task_id, deadline) do
    case Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task_id) do
      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_for_worker(task_id, deadline)
        else
          flunk("Background task #{task_id} did not start a local worker")
        end

      workers ->
        workers
    end
  end

  defp ensure_background_worker_supervisor_started do
    if is_nil(Process.whereis(IntellectualClub.BackgroundTasks.Supervisor)) do
      case Supervisor.restart_child(
             IntellectualClub.Supervisor,
             IntellectualClub.BackgroundTasks.Supervisor
           ) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    else
      :ok
    end
  end

  defp detached_waiting_task do
    Task.Supervisor.async_nolink(
      IntellectualClub.BackgroundTasks.ExecutionSupervisor,
      fn -> Process.sleep(:infinity) end
    )
  end
end
