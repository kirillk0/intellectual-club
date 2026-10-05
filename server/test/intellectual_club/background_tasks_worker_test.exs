defmodule IntellectualClub.BackgroundTasksWorkerTest do
  use IntellectualClub.DataCase, async: true

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.Supervisor, as: TaskSupervisor
  alias IntellectualClub.BackgroundTasks.Worker
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Tools.Drivers.Outlet
  alias IntellectualClub.Tools.Drivers.Ssh
  alias IntellectualClub.Tools.ExecutionResult

  test "worker retries an initial database claim failure" do
    %{user: actor} = user_fixture()
    source = create_source_message!(actor)

    task =
      create_background_task!(actor, %{
        status: :queued,
        source_chat_id: source.chat.id,
        source_message_id: source.message.id,
        execution_context: %{
          "owner_id" => actor.id,
          "chat_id" => source.chat.id,
          "message_id" => source.message.id,
          "assistant_message_id" => source.message.id
        }
      })

    assert {:ok, worker_pid} = TaskSupervisor.start_task(task.id)

    assert wait_until(fn -> :sys.get_state(worker_pid).claim_attempts > 0 end, timeout: 2000)

    assert {:ok, %{status: :queued}} = BackgroundTasks.fetch_internal(task.id)

    assert :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

    assert wait_until(
             fn ->
               case BackgroundTasks.fetch_internal(task.id) do
                 {:ok, %{status: :failed}} -> true
                 _other -> false
               end
             end,
             timeout: 2000
           )
  end

  test "cancel result persistence retries a transient database failure" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now()
      })

    parent = self()

    persister =
      spawn(fn ->
        state = %Worker{task_id: task.id, task: task, pending_result: :canceled}
        first_result = Worker.handle_info(:persist_result, state)
        send(parent, {:first_persist, self(), first_result})

        receive do
          :database_allowed -> :ok
        end

        receive do
          :persist_result ->
            {:noreply, retry_state} = first_result
            send(parent, {:second_persist, Worker.handle_info(:persist_result, retry_state)})
        end
      end)

    assert_receive {:first_persist, ^persister,
                    {:noreply, %Worker{pending_result: :canceled, persist_attempts: 1}}},
                   1_000

    assert :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), persister)
    send(persister, :database_allowed)

    assert_receive {:second_persist, {:stop, :normal, %Worker{pending_result: nil}}}, 1_000
    assert {:ok, %{status: :canceled}} = BackgroundTasks.fetch_internal(task.id)
  end

  test "reconciliation errors cancel the adapter runtime before failing the task" do
    %{user: actor} = user_fixture()

    task =
      create_background_task!(actor, %{
        status: :running,
        started_at: DateTime.utc_now()
      })

    test_process = self()

    assert :ok =
             Ssh.register_background_cancel_ref(
               task.id,
               make_ref(),
               1,
               fn _cancel_ref -> send(test_process, :adapter_runtime_canceled) end
             )

    on_exit(fn ->
      Registry.unregister(
        IntellectualClub.BackgroundTasks.ProcessRegistry,
        {:ssh_background_command, task.id}
      )
    end)

    state = %Worker{task_id: task.id, task: task, waiting?: true}

    assert {:stop, :normal, %Worker{waiting?: false}} =
             Worker.handle_info(:reconcile_wait, state)

    assert_receive :adapter_runtime_canceled
    assert {:ok, %{status: :failed}} = BackgroundTasks.fetch_internal(task.id)
  end

  test "a requested cancel does not resume an orphaned subagent generation" do
    %{user: actor} = user_fixture()
    source = create_source_message!(actor)
    target = create_source_message!(actor)

    task =
      create_background_task!(actor, %{
        adapter: "spawn",
        kind: "spawn",
        function_name: "spawn",
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now(),
        source_chat_id: source.chat.id,
        source_message_id: source.message.id,
        target_chat_id: target.chat.id,
        runner_ref: spawn_runner_ref(target)
      })

    state = %Worker{task_id: task.id, task: task, waiting?: true}

    assert {:stop, :normal, %Worker{waiting?: false}} =
             Worker.handle_info(:reconcile_wait, state)

    assert :not_found == GenerationSupervisor.get_generation_state(target.message.id)
    assert {:ok, %{status: :canceled}} = Ash.get(ChatMessage, target.message.id, actor: actor)
    assert {:ok, %{status: :canceled}} = BackgroundTasks.fetch_internal(task.id)
  end

  test "durable subagent completion wins cancel before the waiting reply is handled" do
    %{user: actor} = user_fixture()
    source = create_source_message!(actor)
    target = create_source_message!(actor)

    set_message_status!(actor, target.message, :done, finished_at: DateTime.utc_now())

    task =
      create_background_task!(actor, %{
        adapter: "spawn",
        kind: "spawn",
        function_name: "spawn",
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now(),
        source_chat_id: source.chat.id,
        source_message_id: source.message.id,
        target_chat_id: target.chat.id,
        runner_ref: spawn_runner_ref(target)
      })

    execution_task = detached_waiting_task()

    reply_tag = make_ref()

    state = %Worker{
      task_id: task.id,
      task: task,
      execution_task: execution_task,
      waiting?: false
    }

    assert {:stop, :normal, %Worker{waiting?: false}} =
             Worker.handle_call(:cancel, {self(), reply_tag}, state)

    assert_receive {^reply_tag, :ok}

    assert {:ok, %{status: :completed, cancel_requested: true}} =
             BackgroundTasks.fetch_internal(task.id)
  end

  test "adapter cancel errors during reconciliation return a valid retry tuple" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "outlet",
        name: "Offline outlet #{System.unique_integer([:positive])}",
        alias: "offline_outlet_#{System.unique_integer([:positive])}",
        config: Outlet.default_config(),
        secrets: %{"token" => Ecto.UUID.generate()}
      })

    task =
      create_background_task!(actor, %{
        adapter: "outlet",
        kind: "outlet_function",
        status: :running,
        cancel_requested: true,
        started_at: DateTime.utc_now(),
        tool_instance_id: tool_instance.id,
        runner_ref: %{
          "runner_id" => "offline-runner",
          "runner_session_id" => "offline-session"
        }
      })

    state = %Worker{task_id: task.id, task: task, waiting?: true}

    assert {:noreply, %Worker{waiting?: true, wait_attempts: 1}} =
             Worker.handle_info(:reconcile_wait, state)

    assert_receive :reconcile_wait, 250

    assert {:ok, %{status: :running, cancel_requested: true}} =
             BackgroundTasks.fetch_internal(task.id)
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

  defp create_source_message!(actor) do
    chat = create_empty_chat!(actor)
    %{chat: chat, message: create_generating_message!(actor, chat, user_text: "Run")}
  end

  defp detached_waiting_task do
    Task.Supervisor.async_nolink(
      IntellectualClub.BackgroundTasks.ExecutionSupervisor,
      fn -> Process.sleep(:infinity) end
    )
  end

  defp spawn_runner_ref(%{message: %ChatMessage{} = message}) do
    %{
      "spawn_prompt_message_id" => message.parent_id,
      "spawn_message_id" => message.id,
      "spawn_generation_message_id" => message.id,
      "spawn_url" => "/chats/#{message.chat_id}"
    }
  end
end
