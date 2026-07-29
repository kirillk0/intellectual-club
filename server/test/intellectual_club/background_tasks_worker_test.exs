defmodule IntellectualClub.BackgroundTasksWorkerTest do
  use IntellectualClub.DataCase, async: true

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.BackgroundTasks.Supervisor, as: TaskSupervisor
  alias IntellectualClub.BackgroundTasks.Worker
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads

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

    assert :ok = wait_until(fn -> :sys.get_state(worker_pid).claim_attempts > 0 end)
    assert {:ok, %{status: :queued}} = BackgroundTasks.fetch_internal(task.id)

    assert :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

    assert :ok =
             wait_until(fn ->
               case BackgroundTasks.fetch_internal(task.id) do
                 {:ok, %{status: :failed}} -> true
                 _other -> false
               end
             end)
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

  defp create_source_message!(actor) do
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

    %{chat: chat, message: message}
  end

  defp wait_until(fun, timeout_ms \\ 2_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_wait_until(fun, deadline)
      else
        flunk("condition was not satisfied before timeout")
      end
    end
  end
end
