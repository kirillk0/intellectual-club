defmodule IntellectualClub.Generation.SupervisorTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.Worker

  defmodule BlockingAdapter do
    @moduledoc false

    def stream_generate(%{context: context}, _emit) do
      send(context.test_pid, {:adapter_started, context.message_id})
      Process.sleep(:infinity)
    end
  end

  defmodule PartialBlockingAdapter do
    @moduledoc false

    def stream_generate(%{context: context}, emit) do
      emit.({:trace, {:set_text, "reasoning", :reasoning, 1, "Partial reasoning"}})
      emit.({:trace, {:set_text, "answer", :answer, 1, "Partial answer"}})
      send(context.test_pid, {:partial_output_ready, context.message_id})
      Process.sleep(:infinity)
    end
  end

  defmodule GlobalWorkerStub do
    @moduledoc false

    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call(:get_current_state, _from, test_pid) do
      {:reply, %{status: :generating, source: :global}, test_pid}
    end

    def handle_call({:poll, cursor, opts}, _from, test_pid) do
      {:reply, %{status: :generating, cursor: cursor, opts: opts, source: :global}, test_pid}
    end

    def handle_call({:steer, text}, _from, test_pid) do
      send(test_pid, {:global_worker_steered, text})
      {:reply, {:ok, %{text: text}}, test_pid}
    end

    def handle_call(:cancel_and_wait, _from, test_pid) do
      send(test_pid, :global_worker_canceled)
      {:stop, :normal, {:error, :not_persisted}, test_pid}
    end

    @impl true
    def handle_cast(:cancel, test_pid) do
      send(test_pid, :global_worker_canceled)
      {:stop, :normal, test_pid}
    end
  end

  test "canceling a fenced worker preserves partial runtime output" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)

    {:ok, user_message} =
      Threads.add_message_to_end(chat, :user, "Generate a partial answer", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => "Generate a partial answer"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)
    assert {:ok, lease} = Lease.acquire(assistant_message.id)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: assistant_message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: PartialBlockingAdapter,
      request_payload: raw_request,
      timeout_ms: 5_000,
      chunk_delay_ms: 0,
      test_pid: self()
    }

    worker =
      start_supervised!(%{
        id: {Worker, assistant_message.id},
        start: {Worker, :start_link, [%{context: context, lease: lease, lease_owner: self()}]},
        restart: :temporary
      })

    monitor_ref = Process.monitor(worker)
    assert_receive {:partial_output_ready, message_id}, 1_000
    assert message_id == assistant_message.id

    assert %{step: %{items: [_reasoning, _answer]}} = Worker.get_current_state(worker)
    assert :ok = GenerationSupervisor.cancel_generation(assistant_message.id)
    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :normal}, 1_000

    message =
      Ash.get!(ChatMessage, assistant_message.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    assert message.status == :canceled
    assert message.token_count > 0
    assert message.generation_fence_token == nil
    assert [step] = message.steps
    assert step.status == :canceled

    items = Enum.sort_by(step.items, & &1.sequence)
    assert item_text(Enum.find(items, &(&1.type == :reasoning))) == "Partial reasoning"
    assert item_text(Enum.find(items, &(&1.type == :answer))) == "Partial answer"
  end

  test "canceling a parent generation cancels active subagent descendant generations" do
    %{user: actor} = user_fixture()
    test_pid = self()

    parent_chat = create_chat!(actor)
    parent_message = start_blocking_generation!(parent_chat, actor, test_pid, "Parent")

    fork_chat =
      create_chat!(actor, %{
        note: "Fork child",
        parent_chat_id: parent_chat.id,
        parent_message_id: parent_message.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    fork_message = start_blocking_generation!(fork_chat, actor, test_pid, "Fork")

    handoff_chat =
      create_chat!(actor, %{
        note: "Handoff child",
        parent_chat_id: fork_chat.id,
        parent_message_id: fork_message.id,
        parent_relation_kind: :handoff,
        subagent: true
      })

    handoff_message = start_blocking_generation!(handoff_chat, actor, test_pid, "Handoff")

    parent_message_id = parent_message.id
    fork_message_id = fork_message.id
    handoff_message_id = handoff_message.id

    assert_receive {:adapter_started, ^parent_message_id}, 1_000
    assert_receive {:adapter_started, ^fork_message_id}, 1_000
    assert_receive {:adapter_started, ^handoff_message_id}, 1_000

    assert :ok = GenerationSupervisor.cancel_generation(parent_message.id)

    assert wait_for_status!(parent_message.id, actor, :canceled).status == :canceled
    assert wait_for_status!(fork_message.id, actor, :canceled).status == :canceled
    assert wait_for_status!(handoff_message.id, actor, :canceled).status == :canceled

    assert GenerationSupervisor.get_generation_state(parent_message.id) == :not_found
    assert GenerationSupervisor.get_generation_state(fork_message.id) == :not_found
    assert GenerationSupervisor.get_generation_state(handoff_message.id) == :not_found
  end

  test "canceling a parent generation cancels an active spawn descendant" do
    %{user: actor} = user_fixture()
    test_pid = self()

    parent_chat = create_chat!(actor)
    parent_message = start_blocking_generation!(parent_chat, actor, test_pid, "Parent")

    spawn_chat =
      create_chat!(actor, %{
        note: "Spawn child",
        parent_chat_id: parent_chat.id,
        parent_message_id: parent_message.id,
        parent_relation_kind: :spawn,
        subagent: true
      })

    spawn_message = start_blocking_generation!(spawn_chat, actor, test_pid, "Spawn")
    parent_message_id = parent_message.id
    spawn_message_id = spawn_message.id

    assert_receive {:adapter_started, ^parent_message_id}, 1_000
    assert_receive {:adapter_started, ^spawn_message_id}, 1_000

    assert :ok = GenerationSupervisor.cancel_generation(parent_message.id)
    assert wait_for_status!(parent_message.id, actor, :canceled).status == :canceled
    assert wait_for_status!(spawn_message.id, actor, :canceled).status == :canceled
    assert GenerationSupervisor.get_generation_state(spawn_message.id) == :not_found
  end

  test "canceling a parent skips an active background fork root" do
    %{user: actor} = user_fixture()
    test_pid = self()

    parent_chat = create_chat!(actor)
    parent_message = start_blocking_generation!(parent_chat, actor, test_pid, "Parent")

    fork_chat =
      create_chat!(actor, %{
        note: "Background fork child",
        parent_chat_id: parent_chat.id,
        parent_message_id: parent_message.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    fork_message = start_blocking_generation!(fork_chat, actor, test_pid, "Background fork")

    _task =
      BackgroundTask
      |> Ash.Changeset.for_create(
        :create,
        %{
          kind: "fork",
          adapter: "fork",
          status: :running,
          function_name: "fork",
          arguments: %{"task" => "Background fork"},
          execution_context: %{},
          source_chat_id: parent_chat.id,
          source_message_id: parent_message.id,
          target_chat_id: fork_chat.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    parent_message_id = parent_message.id
    fork_message_id = fork_message.id

    assert_receive {:adapter_started, ^parent_message_id}, 1_000
    assert_receive {:adapter_started, ^fork_message_id}, 1_000

    assert :ok = GenerationSupervisor.cancel_generation(parent_message.id)
    assert wait_for_status!(parent_message.id, actor, :canceled).status == :canceled
    assert Ash.get!(ChatMessage, fork_message.id, actor: actor).status == :generating

    assert {:ok, %{status: :generating}} =
             GenerationSupervisor.get_generation_state(fork_message.id)

    assert :ok =
             GenerationSupervisor.cancel_generation(fork_message.id,
               include_background_tasks?: true
             )

    assert wait_for_status!(fork_message.id, actor, :canceled).status == :canceled
  end

  test "canceling a parent skips an active background spawn root" do
    %{user: actor} = user_fixture()
    test_pid = self()

    parent_chat = create_chat!(actor)
    parent_message = start_blocking_generation!(parent_chat, actor, test_pid, "Parent")

    spawn_chat =
      create_chat!(actor, %{
        note: "Background spawn child",
        parent_chat_id: parent_chat.id,
        parent_message_id: parent_message.id,
        parent_relation_kind: :spawn,
        subagent: true
      })

    spawn_message = start_blocking_generation!(spawn_chat, actor, test_pid, "Background spawn")

    _task =
      BackgroundTask
      |> Ash.Changeset.for_create(
        :create,
        %{
          kind: "spawn",
          adapter: "spawn",
          status: :running,
          function_name: "spawn",
          arguments: %{"brief" => "Background spawn", "prompt" => "Continue"},
          execution_context: %{},
          source_chat_id: parent_chat.id,
          source_message_id: parent_message.id,
          target_chat_id: spawn_chat.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    parent_message_id = parent_message.id
    spawn_message_id = spawn_message.id

    assert_receive {:adapter_started, ^parent_message_id}, 1_000
    assert_receive {:adapter_started, ^spawn_message_id}, 1_000

    assert :ok = GenerationSupervisor.cancel_generation(parent_message.id)
    assert wait_for_status!(parent_message.id, actor, :canceled).status == :canceled
    assert Ash.get!(ChatMessage, spawn_message.id, actor: actor).status == :generating

    assert {:ok, %{status: :generating}} =
             GenerationSupervisor.get_generation_state(spawn_message.id)

    assert :ok =
             GenerationSupervisor.cancel_generation(spawn_message.id,
               include_background_tasks?: true
             )

    assert wait_for_status!(spawn_message.id, actor, :canceled).status == :canceled
  end

  test "prepared generation preserves its message while canceling other orphans" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Prepared", actor: actor)

    target_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    orphan_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "demo-model",
      "messages" => [%{"role" => "user", "content" => "Prepared"}],
      "stream" => true
    }

    target_step_id = Persistence.ensure_step_started!(target_message.id, 1, raw_request, [])
    _orphan_step_id = Persistence.ensure_step_started!(orphan_message.id, 1, raw_request, [])

    assert {:ok, _context} =
             GenerationSupervisor.start_prepared_generation(
               chat.id,
               target_message.id,
               target_step_id,
               raw_request,
               actor: actor,
               chunk_delay_ms: 60_000
             )

    try do
      target_message = Ash.get!(ChatMessage, target_message.id, actor: actor)
      orphan_message = Ash.get!(ChatMessage, orphan_message.id, actor: actor)

      assert target_message.status == :generating
      assert target_message.error_detail == nil

      assert orphan_message.status == :canceled
      assert orphan_message.error_detail == "Orphaned generation (worker not found)"

      assert {:ok, %{status: :generating}} =
               GenerationSupervisor.get_generation_state(target_message.id)
    after
      _ = GenerationSupervisor.cancel_generation(target_message.id)
    end
  end

  test "generation start lock is released when its holder exits" do
    message_id = System.unique_integer([:positive])

    assert catch_throw(
             GenerationSupervisor.with_generation_start_lock(message_id, fn ->
               throw(:simulated_lock_holder_exit)
             end)
           ) == :simulated_lock_holder_exit

    assert :ok =
             GenerationSupervisor.with_generation_start_lock(message_id, fn -> :ok end)
  end

  test "generation controls find a worker registered only under its global name" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Global", actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _step_id =
      Persistence.ensure_step_started!(message.id, %{
        "model" => "demo-model",
        "messages" => [%{"role" => "user", "content" => "Global"}],
        "stream" => true
      })

    assert {:ok, lease} = Lease.acquire(message.id)
    on_exit(fn -> Lease.release(lease) end)

    stub = start_supervised!({GlobalWorkerStub, self()})
    assert :yes = :global.register_name(Worker.global_name(message.id), stub)

    assert {:ok, %{status: :generating, source: :global}} =
             GenerationSupervisor.get_generation_state(message.id)

    assert {:ok, %{status: :generating, source: :global, cursor: %{step: 1}}} =
             GenerationSupervisor.poll_generation(message.id, %{step: 1})

    assert {:ok, %{text: "Continue"}} =
             GenerationSupervisor.steer_generation(message.id, "Continue")

    assert_receive {:global_worker_steered, "Continue"}

    assert :ok = GenerationSupervisor.cancel_generation(message.id)
    assert_receive :global_worker_canceled
    canceled = wait_for_status!(message.id, actor, :canceled)
    assert canceled.generation_fence_token == nil
    assert GenerationSupervisor.get_generation_state(message.id) == :not_found
  end

  defp create_chat!(actor, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      Map.merge(%{note: ""}, attrs),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp start_blocking_generation!(%Chat{} = chat, actor, test_pid, prompt) do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, prompt, actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => prompt}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: assistant_message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: BlockingAdapter,
      request_payload: raw_request,
      timeout_ms: 1_000,
      chunk_delay_ms: 0,
      test_pid: test_pid
    }

    {:ok, _pid} = Worker.start_link(%{context: context})
    assistant_message
  end

  defp wait_for_status!(message_id, actor, wanted_status) do
    deadline = System.monotonic_time(:millisecond) + 4_000
    do_wait_for_status!(message_id, actor, wanted_status, deadline)
  end

  defp item_text(item) do
    item.contents
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map_join("", &to_string(&1.content_text || ""))
  end

  defp do_wait_for_status!(message_id, actor, wanted_status, deadline) do
    message = Ash.get!(ChatMessage, message_id, actor: actor)

    if message.status == wanted_status do
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_status!(message_id, actor, wanted_status, deadline)
      else
        flunk("Message #{message_id} did not reach #{inspect(wanted_status)}")
      end
    end
  end
end
