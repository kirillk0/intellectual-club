defmodule IntellectualClub.Generation.SupervisorTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Test.GenerationRuntime

  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.{ChatMessage, ChatMessageStep, QueuedMessages, Threads}
  alias IntellectualClub.Generation.{Lease, LegacyGenerationSnapshotStub, Persistence, Worker}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  describe "cascading cancellation" do
    test "canceling a message preserves the other branch and its subagent lineage" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      first = start_blocking_generation!(actor, chat, "First branch")
      second = start_blocking_generation!(actor, chat, "Second branch")

      first_child =
        start_blocking_generation!(actor, child_chat!(actor, first, :fork), "First child")

      second_child =
        start_blocking_generation!(actor, child_chat!(actor, second, :spawn), "Second child")

      second_grandchild =
        start_blocking_generation!(
          actor,
          child_chat!(actor, second_child, :handoff),
          "Second handoff"
        )

      second_pid = GenerationSupervisor.generation_worker_pid(second.message.id)
      second_token = Ash.get!(ChatMessage, second.message.id, actor: actor).generation_fence_token

      assert :ok = GenerationSupervisor.cancel_generation(first.message.id)
      for generation <- [first, first_child], do: assert_canceled!(actor, generation)

      for generation <- [second, second_child, second_grandchild] do
        assert Ash.get!(ChatMessage, generation.message.id, actor: actor).status == :generating

        assert {:ok, %{status: :generating}} =
                 GenerationSupervisor.poll_generation(generation.message.id)
      end

      assert GenerationSupervisor.generation_worker_pid(second.message.id) == second_pid

      assert Ash.get!(ChatMessage, second.message.id, actor: actor).generation_fence_token ==
               second_token

      assert :ok = GenerationSupervisor.cancel_for_chat(chat.id)

      for generation <- [second, second_child, second_grandchild],
          do: assert_canceled!(actor, generation)
    end

    test "canceling a message finds a child through its originating tool call" do
      %{user: actor} = user_fixture()
      parent = start_blocking_generation!(actor, create_empty_chat!(actor), "Parent")
      step = Ash.get!(ChatMessageStep, parent.step_id, actor: actor)
      item = create_item!(actor, step, type: :tool_call)

      chat = create_subchat!(actor, parent.chat, :spawn, parent_tool_call_item_id: item.id)
      child = start_blocking_generation!(actor, chat, "Tool-owned child")
      orphan = create_generating_message!(actor, chat, parent_id: child.message.parent_id)

      assert Ash.get!(IntellectualClub.Chat.Chat, chat.id, actor: actor).parent_tool_call_item_id ==
               item.id

      assert :ok = GenerationSupervisor.cancel_generation(parent.message.id)

      for generation <- [parent, child], do: assert_canceled!(actor, generation)
      assert Ash.get!(ChatMessage, orphan.id, actor: actor).status == :canceled
    end

    test "canceling a chat stops all its workers and fails its orphaned messages" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      first = start_blocking_generation!(actor, chat, "First branch")
      second = start_blocking_generation!(actor, chat, "Second branch")
      child = start_blocking_generation!(actor, child_chat!(actor, second, :fork), "Child")
      orphan = create_generating_message!(actor, chat, parent_id: first.message.parent_id)

      assert :ok = GenerationSupervisor.cancel_for_chat(chat.id)
      for generation <- [first, second, child], do: assert_canceled!(actor, generation)
      assert Ash.get!(ChatMessage, orphan.id, actor: actor).status == :error
    end

    for {relation, grandchild?} <- [fork: true, spawn: false] do
      @tag relation: relation, grandchild?: grandchild?
      test "canceling a parent cancels an active #{relation} descendant#{if grandchild?, do: " and its handoff child"}",
           %{relation: relation, grandchild?: grandchild?} do
        %{user: actor} = user_fixture()
        parent = start_blocking_generation!(actor, create_empty_chat!(actor), "Parent")
        child = start_blocking_generation!(actor, child_chat!(actor, parent, relation), "Child")

        descendants =
          if grandchild? do
            [
              child,
              start_blocking_generation!(actor, child_chat!(actor, child, :handoff), "Handoff")
            ]
          else
            [child]
          end

        assert :ok = GenerationSupervisor.cancel_generation(parent.message.id)
        for generation <- [parent | descendants], do: assert_canceled!(actor, generation)
      end
    end

    for {kind, arguments} <- [
          fork: %{"task" => "Background fork"},
          spawn: %{"brief" => "Background spawn", "prompt" => "Continue"}
        ] do
      @tag kind: kind, arguments: arguments
      test "canceling a parent cancels its active background #{kind} task and the child's nested work",
           %{kind: kind, arguments: arguments} do
        %{user: actor} = user_fixture()
        parent = start_blocking_generation!(actor, create_empty_chat!(actor), "Parent")
        child = start_blocking_generation!(actor, child_chat!(actor, parent, kind), "Child")
        task = background_child_task!(actor, parent, child, Atom.to_string(kind), arguments)

        nested_task =
          create!(
            BackgroundTask,
            %{
              kind: "ssh_command",
              adapter: "ssh",
              status: :queued,
              function_name: "run_command",
              arguments: %{"command" => "echo nested"},
              execution_context: %{
                "owner_id" => actor.id,
                "chat_id" => child.chat.id,
                "message_id" => child.message.id,
                "assistant_message_id" => child.message.id
              },
              source_chat_id: child.chat.id,
              source_message_id: child.message.id
            },
            actor
          )

        assert :ok = GenerationSupervisor.cancel_generation(parent.message.id)
        for generation <- [parent, child], do: assert_canceled!(actor, generation)

        for task <- [task, nested_task] do
          assert wait_for_background_task_status!(task.id, actor, :canceled).cancel_requested
        end
      end
    end
  end

  describe "orphans and prepared generations" do
    test "a prepared generation preserves neighboring workers and orphans" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Prepared", actor: actor)
      attrs = %{parent_id: user_message.id, token_count: 0}
      target_message = create_generating_message!(actor, chat, attrs)
      orphan_message = create_generating_message!(actor, chat, attrs)

      raw_request = %{
        "model" => "demo-model",
        "messages" => [%{"role" => "user", "content" => "Prepared"}],
        "stream" => true
      }

      target_step_id = Persistence.ensure_step_started!(target_message.id, 1, raw_request, [])
      _orphan_step_id = Persistence.ensure_step_started!(orphan_message.id, 1, raw_request, [])

      neighbor = start_blocking_generation!(actor, chat, "Neighbor")
      neighbor_pid = GenerationSupervisor.generation_worker_pid(neighbor.message.id)

      assert {:ok, queued_message} =
               QueuedMessages.enqueue_follow_up(
                 chat.id,
                 %{content: "Continue after the orphan"},
                 actor
               )

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
        assert orphan_message.status == :generating
        assert orphan_message.error_detail == nil
        assert Ash.get!(ChatMessage, neighbor.message.id, actor: actor).status == :generating
        assert GenerationSupervisor.generation_worker_pid(neighbor.message.id) == neighbor_pid

        assert {:ok, queued} = QueuedMessages.get(queued_message.id, actor)
        assert queued.status == :pending
        assert queued.blocked_reason == nil

        assert {:ok, %{status: :generating}} =
                 GenerationSupervisor.get_generation_state(target_message.id)
      after
        _ = GenerationSupervisor.cancel_for_chat(chat.id)
      end
    end
  end

  describe "worker lookup and start lock" do
    test "chat lookup returns every message worker while duplicate starts remain fenced" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      first = generation_fixture!(actor: actor, chat: chat, prompt: "First")

      second_message =
        create_generating_message!(actor, chat,
          parent_id: first.message.parent_id,
          llm_configuration_id: first.configuration.id
        )

      second_step_id =
        Persistence.ensure_step_started!(second_message.id, first.context.request_payload)

      second = %{
        first
        | message: second_message,
          step_id: second_step_id,
          context: %{first.context | message_id: second_message.id, step_id: second_step_id}
      }

      first_pid = start_worker!(first)
      second_pid = start_worker!(second)
      await_provider!(first)
      await_provider!(second)

      ids = Enum.sort([first.message.id, second.message.id])
      candidates = GenerationSupervisor.active_generation_candidates([chat.id, chat.id], ids)
      assert Enum.sort(Enum.map(candidates.chat_generations, & &1.message_id)) == ids
      assert Enum.sort(Enum.map(candidates.message_generations, & &1.message_id)) == ids

      assert Enum.all?(
               candidates.chat_generations,
               &(&1.chat_id == chat.id and &1.owner_id == actor.id)
             )

      assert Registry.lookup(IntellectualClub.Generation.Registry, {:chat, chat.id}) == []
      assert GenerationSupervisor.generation_worker_pid(first.message.id) == first_pid
      assert GenerationSupervisor.generation_worker_pid(second.message.id) == second_pid
      assert :global.whereis_name(Worker.global_name(first.message.id)) == first_pid
      assert :global.whereis_name(Worker.global_name(second.message.id)) == second_pid

      assert {:error, :already_running} =
               GenerationSupervisor.start_prepared_context(first.context)

      assert {:error, :already_running} = Lease.reserve(first.message.id)
      assert {:error, :already_running} = Lease.reserve(second.message.id)
      assert :ok = GenerationSupervisor.cancel_for_chat(chat.id)
    end

    test "the generation start lock is released when its holder exits" do
      message_id = System.unique_integer([:positive])

      assert catch_throw(
               GenerationSupervisor.with_generation_start_lock(message_id, fn ->
                 throw(:simulated_lock_holder_exit)
               end)
             ) == :simulated_lock_holder_exit

      assert :ok = GenerationSupervisor.with_generation_start_lock(message_id, fn -> :ok end)
    end

    test "generation controls find a worker registered only under its global name" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      message = create_generating_message!(actor, chat, %{user_text: "Global", token_count: 0})

      step_id =
        Persistence.ensure_step_started!(message.id, %{
          "model" => "demo-model",
          "messages" => [%{"role" => "user", "content" => "Global"}],
          "stream" => true
        })

      assert {:ok, queued_message} =
               QueuedMessages.enqueue_follow_up(
                 chat.id,
                 %{content: "Continue after fallback cancellation"},
                 actor
               )

      assert {:ok, lease} = Lease.acquire(message.id)
      on_exit(fn -> Lease.release(lease) end)

      stub = start_supervised!({LegacyGenerationSnapshotStub, self()})
      assert :yes = :global.register_name(Worker.global_name(message.id), stub)
      assert Registry.lookup(IntellectualClub.Generation.Registry, {:message, message.id}) == []

      assert {:busy, %{status: :generating, phase: :initializing, step: nil}} =
               GenerationSupervisor.get_generation_state(message.id)

      assert {:busy, %{status: :generating, phase: :initializing, step: nil}} =
               GenerationSupervisor.poll_generation(message.id, %{step: 1})

      assert Ash.get!(ChatMessage, message.id, actor: actor).status == :generating

      assert :ok =
               GenServer.call(
                 stub,
                 {:publish_snapshot, message.id,
                  %{
                    status: :generating,
                    phase: :persisting,
                    step: %{id: step_id, sequence: 1, status: "waiting_provider", items: []}
                  }}
               )

      assert {:ok, snapshot} = GenerationSupervisor.get_generation_state(message.id)
      assert %{status: :generating, phase: :persisting, step: %{id: ^step_id}} = snapshot

      # A suspended worker never answers; keep the busy fallback fast.
      put_app_env(:generation_poll_timeout_ms, 100)
      :ok = :sys.suspend(stub)

      try do
        assert {:busy, %{status: :generating}} =
                 GenerationSupervisor.get_generation_state(message.id)

        assert {:busy, %{status: :generating}} =
                 GenerationSupervisor.poll_generation(message.id, %{step: 1},
                   include_working: true
                 )
      after
        :sys.resume(stub)
      end

      monitor = Process.monitor(stub)
      assert :ok = GenerationSupervisor.cancel_generation(message.id)
      assert_receive :global_worker_canceled
      assert_receive {:DOWN, ^monitor, :process, ^stub, :normal}
      canceled = wait_for_message_status!(message.id, actor, :canceled)
      assert canceled.generation_fence_token == nil

      assert {:ok, blocked} = QueuedMessages.get(queued_message.id, actor)
      assert blocked.status == :blocked
      assert blocked.blocked_reason == "generation_canceled"
      assert GenerationSupervisor.get_generation_state(message.id) == :not_found
    end
  end

  describe "retry_from_step/3" do
    test "retrying a completed branch preserves another active worker" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, _input} = Threads.add_message_to_end(chat, :user, "Retry this", actor: actor)
      {:ok, message} = Threads.add_message_to_end(chat, :assistant, "Original", actor: actor)

      step =
        create_step!(actor, message, %{
          sequence: 2,
          raw_request: %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Retry this"}],
            "stream" => true
          },
          response_final: true
        })

      neighbor = start_blocking_generation!(actor, chat, "Other branch")

      neighbor.message
      |> Ash.Changeset.for_update(:reparent, %{parent_id: message.parent_id}, actor: actor)
      |> Ash.update!()

      neighbor_pid = GenerationSupervisor.generation_worker_pid(neighbor.message.id)

      neighbor_token =
        Ash.get!(ChatMessage, neighbor.message.id, actor: actor).generation_fence_token

      try do
        assert {:ok, _context} =
                 GenerationSupervisor.retry_from_step(message.id, step.id,
                   actor: actor,
                   chunk_delay_ms: 60_000
                 )

        assert Ash.get!(ChatMessage, neighbor.message.id, actor: actor).status == :generating
        assert GenerationSupervisor.generation_worker_pid(neighbor.message.id) == neighbor_pid

        assert Ash.get!(ChatMessage, neighbor.message.id, actor: actor).generation_fence_token ==
                 neighbor_token

        assert {:ok, %{status: :generating}} = GenerationSupervisor.poll_generation(message.id)
      after
        GenerationSupervisor.cancel_for_chat(chat.id)
      end
    end

    test "retrying an ancestor of an active generation leaves its steps and worker untouched" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, message} = Threads.add_message_to_end(chat, :assistant, "Original", actor: actor)

      step =
        create_step!(actor, message,
          sequence: 2,
          raw_request: %{"model" => "demo-model", "messages" => []},
          response_final: true
        )

      child = start_blocking_generation!(actor, chat, "Dependent answer")

      child.message
      |> Ash.Changeset.for_update(:reparent, %{parent_id: message.id}, actor: actor)
      |> Ash.update!()

      pid = GenerationSupervisor.generation_worker_pid(child.message.id)

      try do
        assert {:error, :generation_active} =
                 GenerationSupervisor.retry_from_step(message.id, step.id, actor: actor)

        assert Ash.get!(ChatMessageStep, step.id, actor: actor).id == step.id
        assert Ash.get!(ChatMessage, message.id, actor: actor).status == :done
        assert Ash.get!(ChatMessage, message.id, actor: actor).generation_fence_token == nil
        assert GenerationSupervisor.generation_worker_pid(child.message.id) == pid
        assert Ash.get!(ChatMessage, child.message.id, actor: actor).status == :generating
      after
        GenerationSupervisor.cancel_for_chat(chat.id)
      end
    end

    test "a step disappearing before cleanup preflight cannot publish a retry fence" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, _input} = Threads.add_message_to_end(chat, :user, "Reply briefly", actor: actor)

      {:ok, message} =
        Threads.add_message_to_end(chat, :assistant, "Original response", actor: actor)

      step =
        create_step!(actor, message, %{
          sequence: 2,
          raw_request: %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Reply briefly"}],
            "stream" => true
          },
          response_final: true
        })

      handler = {__MODULE__, make_ref()}
      caller = self()
      scope = {:steps, message.id, step.sequence}

      # Remove the already-read source at the exact preflight boundary. This
      # deterministic fault injection needs no timing race or provider process.
      :ok =
        :telemetry.attach(
          handler,
          [:intellectual_club, :linked_fork_cleanup, :plan],
          fn _, _, metadata, _ ->
            if self() == caller and metadata.scope == scope do
              Ash.destroy!(step, actor: actor)
              send(caller, :source_removed_before_retry_locks)
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, :retry_step_not_found} =
               GenerationSupervisor.retry_from_step(message.id, step.id, actor: actor)

      assert_received :source_removed_before_retry_locks
      current = Ash.get!(ChatMessage, message.id, actor: actor)
      assert current.generation_fence_token == nil
      assert current.status == :done
      assert GenerationSupervisor.get_generation_state(message.id) == :not_found
    end
  end

  # A generation in `chat` whose provider blocks until the Worker is canceled.
  defp start_blocking_generation!(actor, chat, prompt) do
    fixture = generation_fixture!(actor: actor, chat: chat, prompt: prompt)
    start_worker!(fixture)
    await_provider!(fixture)
    fixture
  end

  # The durable status is committed before the Worker finishes stopping.
  defp assert_canceled!(actor, generation) do
    canceled =
      wait_for_message_status!(generation.message.id, actor, :canceled, stop_worker: true)

    assert canceled.status == :canceled
    assert GenerationSupervisor.get_generation_state(generation.message.id) == :not_found
  end

  defp child_chat!(actor, parent, relation_kind) do
    create_empty_chat!(actor, %{
      note: "#{relation_kind} child",
      parent_chat_id: parent.chat.id,
      parent_message_id: parent.message.id,
      parent_relation_kind: relation_kind,
      subagent: true
    })
  end

  defp background_child_task!(actor, parent, child, kind, arguments) do
    create!(
      BackgroundTask,
      %{
        kind: kind,
        adapter: kind,
        status: :running,
        function_name: kind,
        arguments: arguments,
        execution_context: %{},
        source_chat_id: parent.chat.id,
        source_message_id: parent.message.id,
        target_chat_id: child.chat.id
      },
      actor
    )
  end
end
