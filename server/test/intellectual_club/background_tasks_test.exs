defmodule IntellectualClub.BackgroundTasksTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.SubagentFixtures

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.BackgroundTasks.Reaper
  alias IntellectualClub.BackgroundTasks.Supervisor, as: TaskSupervisor
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Tools.Drivers.Ssh
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  describe "start_tool/4" do
    test "is idempotent for a persisted source tool call" do
      %{user: actor} = user_fixture()
      source = create_source_tool_call!(actor)
      tool_instance = create_ssh_tool_instance!(actor)
      context = tool_call_context(source, actor)
      payload = %{"command" => "echo once", "timeout_seconds" => 1}

      assert {:ok, first} =
               BackgroundTasks.start_tool(tool_instance, "run_command", payload, context)

      assert {:ok, repeated} =
               BackgroundTasks.start_tool(tool_instance, "run_command", payload, context)

      task_id = first.raw["background_task_id"]
      assert Ecto.UUID.cast(task_id) == {:ok, task_id}
      assert repeated.raw["background_task_id"] == task_id

      assert [%BackgroundTask{id: ^task_id, arguments: ^payload} = task] =
               BackgroundTask
               |> Ash.Query.filter(source_tool_call_item_id == ^source.item.id)
               |> Ash.read!(actor: actor)

      assert task.lifecycle_message_id == source.message.id
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

    for {label, end_parent} <- [
          canceled: &__MODULE__.cancel_parent!/2,
          completed: &__MODULE__.complete_parent!/2
        ] do
      test "rejects a #{label} parent generation even while its old epoch is retained" do
        %{user: actor} = user_fixture()
        source = create_source_tool_call!(actor)
        tool_instance = create_ssh_tool_instance!(actor)
        assert {:ok, lease} = Lease.acquire(source.message.id)
        context = tool_call_context(source, actor, generation_fence_token: lease.fence_token)
        unquote(end_parent).(source, actor)
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
    end

    test "claim fails closed after the source generation becomes terminal" do
      %{user: actor} = user_fixture()
      source = create_source_tool_call!(actor)
      task = create_background_task!(actor, source_message_attrs(source, actor))

      complete_parent!(source, actor)

      assert {:ok, canceled} = BackgroundTasks.mark_running(task)
      assert canceled.status == :canceled
      assert canceled.cancel_requested == true
      assert canceled.started_at == nil
    end
  end

  describe "lifecycle" do
    test "lifecycle cancellation marks only active tasks" do
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

      requested_ids = BackgroundTasks.request_cancel_for_lifecycle_message!(source.message.id)

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

    test "handoff transfers active task lifecycle without changing provenance" do
      %{user: actor} = user_fixture()
      source = create_source_tool_call!(actor)
      child = create_source_tool_call!(actor)
      unrelated_source = create_source_tool_call!(actor)

      queued = create_background_task!(actor, source_message_attrs(source, actor))

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

      canceling =
        create_background_task!(
          actor,
          source
          |> source_message_attrs(actor)
          |> Map.put(:cancel_requested, true)
        )

      unrelated =
        create_background_task!(actor, source_message_attrs(unrelated_source, actor))

      set_message_status!(actor, source.message, :done, finished_at: DateTime.utc_now())

      transferred_ids =
        BackgroundTasks.transfer_active_for_handoff!(source.message.id, child.message.id)

      assert MapSet.new(transferred_ids) == MapSet.new([queued.id, running.id])

      assert {:ok, transferred_queued} = BackgroundTasks.fetch_internal(queued.id)
      assert transferred_queued.lifecycle_message_id == child.message.id
      assert transferred_queued.source_message_id == source.message.id
      assert transferred_queued.source_chat_id == source.chat.id
      assert transferred_queued.execution_context["message_id"] == source.message.id

      assert {:ok, transferred_running} = BackgroundTasks.fetch_internal(running.id)
      assert transferred_running.lifecycle_message_id == child.message.id

      assert {:ok, unchanged_completed} = BackgroundTasks.fetch_internal(completed.id)
      assert unchanged_completed.lifecycle_message_id == source.message.id

      assert {:ok, unchanged_canceling} = BackgroundTasks.fetch_internal(canceling.id)
      assert unchanged_canceling.lifecycle_message_id == source.message.id

      assert {:ok, unchanged_unrelated} = BackgroundTasks.fetch_internal(unrelated.id)
      assert unchanged_unrelated.lifecycle_message_id == unrelated_source.message.id

      assert [canceling_id] =
               BackgroundTasks.request_cancel_for_lifecycle_message!(source.message.id)

      assert canceling_id == canceling.id

      requested_child_ids =
        BackgroundTasks.request_cancel_for_lifecycle_message!(child.message.id)

      assert MapSet.new(requested_child_ids) == MapSet.new([queued.id, running.id])
    end

    test "transferred lifecycle authorizes queued work after the source is done" do
      %{user: actor} = user_fixture()
      source = create_source_tool_call!(actor)
      child = create_source_tool_call!(actor)

      task =
        create_background_task!(
          actor,
          source
          |> source_message_attrs(actor)
          |> Map.merge(%{
            source_step_id: source.step.id,
            source_tool_call_item_id: source.item.id
          })
        )

      set_message_status!(actor, source.message, :done, finished_at: DateTime.utc_now())

      assert [task_id] =
               BackgroundTasks.transfer_active_for_handoff!(source.message.id, child.message.id)

      assert task_id == task.id
      assert {:ok, running} = BackgroundTasks.mark_running(task)
      assert running.status == :running
      assert running.lifecycle_message_id == child.message.id

      context = tool_call_context(source, actor)

      assert :authorized ==
               BackgroundTasks.with_active_task_authority(task, context, fn -> :authorized end)
    end

    test "failed handoff transfer leaves the original lifecycle unchanged" do
      %{user: actor} = user_fixture()
      source = create_source_tool_call!(actor)
      invalid_child = create_source_tool_call!(actor)
      task = create_background_task!(actor, source_message_attrs(source, actor))

      set_message_status!(actor, source.message, :done, finished_at: DateTime.utc_now())
      set_message_status!(actor, invalid_child.message, :done, finished_at: DateTime.utc_now())

      assert_raise RuntimeError, ~r/invalid_background_task_handoff_lifecycle/, fn ->
        BackgroundTasks.transfer_active_for_handoff!(
          source.message.id,
          invalid_child.message.id
        )
      end

      assert {:ok, unchanged} = BackgroundTasks.fetch_internal(task.id)
      assert unchanged.lifecycle_message_id == source.message.id
      assert unchanged.cancel_requested == false
    end

    test "task lifecycle follows repeated handoffs and cancels at the final boundary" do
      %{user: actor} = user_fixture()
      source = create_source_tool_call!(actor)
      first_child = create_source_tool_call!(actor)
      second_child = create_source_tool_call!(actor)
      task = create_background_task!(actor, source_message_attrs(source, actor))

      set_message_status!(actor, source.message, :done, finished_at: DateTime.utc_now())

      assert [task_id] =
               BackgroundTasks.transfer_active_for_handoff!(
                 source.message.id,
                 first_child.message.id
               )

      assert task_id == task.id
      set_message_status!(actor, first_child.message, :done, finished_at: DateTime.utc_now())

      assert [^task_id] =
               BackgroundTasks.transfer_active_for_handoff!(
                 first_child.message.id,
                 second_child.message.id
               )

      assert {:ok, twice_transferred} = BackgroundTasks.fetch_internal(task.id)
      assert twice_transferred.lifecycle_message_id == second_child.message.id
      assert twice_transferred.source_message_id == source.message.id

      set_message_status!(actor, second_child.message, :done, finished_at: DateTime.utc_now())

      assert [^task_id] =
               BackgroundTasks.request_cancel_for_lifecycle_message!(second_child.message.id)

      assert {:ok, canceling} = BackgroundTasks.fetch_internal(task.id)
      assert canceling.cancel_requested == true
    end
  end

  describe "execution context and references" do
    test "execution context is rebuilt from its persisted JSON shape" do
      %{user: actor} = user_fixture()
      created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      generation_fence_token = Ecto.UUID.generate()

      task =
        create_background_task!(actor, %{
          execution_context: %{
            "owner_id" => actor.id,
            "chat_id" => 101,
            "root_chat_id" => 99,
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
      assert context.root_chat_id == 99
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
  end

  describe "snapshot and cancel" do
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
  end

  describe "live reaper" do
    test "live reaper keeps a transferred task while its lifecycle generation is active" do
      %{user: actor} = user_fixture()
      source = create_source_tool_call!(actor)
      child = create_source_tool_call!(actor)

      task =
        create_background_task!(
          actor,
          source
          |> source_message_attrs(actor)
          |> Map.merge(%{status: :running, started_at: DateTime.utc_now()})
        )

      set_message_status!(actor, source.message, :done, finished_at: DateTime.utc_now())

      assert [task_id] =
               BackgroundTasks.transfer_active_for_handoff!(source.message.id, child.message.id)

      assert task_id == task.id

      assert {:ok, _owner} =
               Registry.register(
                 IntellectualClub.BackgroundTasks.ProcessRegistry,
                 task.id,
                 nil
               )

      assert :ok = Reaper.sweep()
      assert {:ok, current} = BackgroundTasks.fetch_internal(task.id)
      assert current.status == :running
      assert current.cancel_requested == false
      assert current.lifecycle_message_id == child.message.id

      Registry.unregister(IntellectualClub.BackgroundTasks.ProcessRegistry, task.id)
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

      context = tool_call_context(source, actor)

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

      assert wait_until(fn -> :sys.get_state(reaper).failure_count > 0 end)

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

      complete_parent!(source, actor)

      assert [task_id] =
               BackgroundTasks.request_cancel_for_lifecycle_message!(source.message.id)

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
  end

  @doc false
  def cancel_parent!(source, _actor) do
    assert :canceled =
             Persistence.cancel_generating_message!(source.message.id, error_detail: nil)
  end

  @doc false
  def complete_parent!(source, actor) do
    set_message_status!(actor, source.message, :done, finished_at: DateTime.utc_now())
  end

  defp source_message_attrs(source, actor) do
    %{
      source_chat_id: source.chat.id,
      source_message_id: source.message.id,
      lifecycle_message_id: source.message.id,
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

  defp wait_for_terminal_status(task_id, owner_id) do
    wait_until(
      fn ->
        {:ok, snapshot} = BackgroundTasks.snapshot(task_id, nil, owner_id)
        snapshot["status"] in ["completed", "failed", "canceled"] && snapshot["status"]
      end,
      timeout: 3_000,
      interval: 20,
      message: "Background task #{task_id} did not reach a terminal status"
    )
  end

  defp wait_for_worker(task_id) do
    wait_until(
      fn ->
        case Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task_id) do
          [] -> nil
          workers -> workers
        end
      end,
      message: "Background task #{task_id} did not start a local worker"
    )
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
end
