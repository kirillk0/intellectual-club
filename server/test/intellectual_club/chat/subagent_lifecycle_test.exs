defmodule IntellectualClub.Chat.SubagentLifecycleTest do
  @moduledoc """
  Fork and spawn subagents from the parent tool call to the parent receipt:
  child preparation, durable references, fencing against stale parent epochs,
  concurrent starts and background execution through the durable task adapter.

  Recovery of orphaned parents and children lives in
  `IntellectualClub.Generation.OrphanedRecoveryTest`.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.SubagentFixtures

  import IntellectualClub.TestSupport.Subagents.GatedProvider,
    only: [
      await_gated_generation!: 0,
      create_gated_configuration!: 1,
      gate_generations!: 0,
      release_gated_generation: 1
    ]

  require Ash.Query

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageItem,
    ChatMessageStep,
    ChatShare,
    Fork,
    ForkBoundary,
    Previews,
    Spawn,
    Threads
  }

  alias IntellectualClub.Generation.{History, Lease, Persistence, QueueCoordinator, RuntimeTrace}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.ToolResult
  alias IntellectualClub.SqlCapture
  alias IntellectualClub.Tools.Drivers.NativeAgentManagement
  alias IntellectualClub.Tools.ExecutionResult

  describe "fork" do
    test "returns a new child result before the parent writer persists its receipt" do
      %{user: actor} = user_fixture()
      task = "Create a fresh fork"
      parent = fork_parent!(actor, task)
      assert {:ok, lease} = Lease.acquire(parent.message.id)

      try do
        context = tool_call_context(parent, actor, generation_fence_token: lease.fence_token)

        assert {:ok, %ExecutionResult{} = result} =
                 NativeAgentManagement.execute(
                   parent.tool_instance,
                   "fork",
                   %{"brief" => "  Fork summary  ", "prompt" => "  " <> task <> "  "},
                   context
                 )

        assert %{
                 "chat_id" => child_chat_id,
                 "message_id" => child_message_id,
                 "generation_message_id" => child_message_id,
                 "final_chat_id" => child_chat_id,
                 "final_message_id" => child_message_id
               } = result.raw["fork"]

        child_chat = Ash.get!(Chat, child_chat_id, actor: actor)
        assert child_chat.note == "Fork summary"
        assert child_chat.fork_task == task
        refute result.raw["isError"]
        assert subchat_ids_for_call(actor, parent.call.item_id) == [child_chat_id]

        child_message = Ash.get!(ChatMessage, child_message_id, actor: actor)
        assert child_message.status == :done
        assert child_message.error_detail == nil

        parent_message = load_message!(parent.message.id, actor)
        assert parent_message.status == :generating
        assert tool_result_items(parent_message, parent.call.item_id) == []
        assert [missing] = Persistence.list_missing_tool_calls!(parent.step_id)
        assert missing.item_id == parent.call.item_id

        assert {:ok, %ToolResult{} = receipt} = persist_parent_receipt(parent, lease, result)
        assert receipt.tool_call_item_id == parent.call.item_id
        assert receipt.result_raw == result.raw
        assert receipt.text == result.text
        assert Persistence.list_missing_tool_calls!(parent.step_id) == []

        parent_message = load_message!(parent.message.id, actor)
        assert [persisted] = tool_result_items(parent_message, parent.call.item_id)
        assert persisted.id == receipt.item_id
        assert tool_result_raw(parent_message, parent.call.item_id) == result.raw
      after
        Lease.release(lease)
      end
    end

    test "announces functions rejected by child policy without changing its tools" do
      %{user: actor} = user_fixture()
      task = "Work without nested subchats"

      tools =
        for name <- ["fork", "handoff", "sleep"] do
          %{
            "type" => "function",
            "function" => %{
              "name" => "agent_management__#{name}",
              "description" => "",
              "parameters" => %{"type" => "object", "properties" => %{}}
            }
          }
        end

      parent = fork_parent!(actor, task, tools: tools)
      assert {:ok, lease} = Lease.acquire(parent.message.id)

      try do
        context = tool_call_context(parent, actor, generation_fence_token: lease.fence_token)

        assert {:ok, %ExecutionResult{} = result} =
                 NativeAgentManagement.execute(
                   parent.tool_instance,
                   "fork",
                   %{"brief" => "Fork summary", "prompt" => task},
                   context
                 )

        unavailable = ["agent_management__fork", "agent_management__handoff"]
        steering = ForkBoundary.steering(task, unavailable)
        child_chat = Ash.get!(Chat, result.raw["fork"]["chat_id"], actor: actor)
        assert child_chat.fork_unavailable_functions == unavailable

        first_step =
          ChatMessageStep
          |> Ash.Query.filter(
            chat_message_id == ^result.raw["fork"]["message_id"] and sequence == 1
          )
          |> Ash.read_one!(actor: actor)
          |> Ash.load!([:raw_request], actor: actor)

        assert List.last(first_step.raw_request["messages"]) == %{
                 "role" => "user",
                 "content" => steering
               }
      after
        Lease.release(lease)
      end
    end

    test "refuses an unfinished source response before publishing a child" do
      %{user: actor} = user_fixture()
      task = "Do not start from streaming context"
      parent = fork_parent!(actor, task)

      ChatMessageStep
      |> Ash.get!(parent.step_id, actor: actor)
      |> Ash.Changeset.for_update(:update, %{response_final: false}, actor: actor)
      |> Ash.update!(actor: actor)

      assert {:error, :invalid_fork_source} =
               start_or_resume(:fork, parent, tool_call_context(parent, actor), actor)

      assert subchat_ids_for_call(actor, parent.call.item_id) == []
    end

    test "preserves the parallel provider response without copying historical steps" do
      %{user: actor} = user_fixture()
      selected_task = "Investigate the selected branch"
      parent = parallel_fork_parent!(actor, "Investigate the sibling branch", selected_task)
      context = tool_call_context(parent, actor)
      test_process = self()

      starter =
        Task.async(fn ->
          Fork.start_or_resume(
            parent.tool_instance,
            "Selected branch",
            selected_task,
            context,
            actor,
            on_reference: fn reference ->
              send(test_process, {:parallel_fork_prepared, self(), reference})

              receive do
                :continue_parallel_fork -> :ok
              after
                5_000 -> {:error, :parallel_fork_barrier_timeout}
              end
            end
          )
        end)

      assert_receive {:parallel_fork_prepared, starter_pid, reference}, 5_000

      child_message =
        Ash.get!(ChatMessage, reference.generation_message_id,
          actor: actor,
          load: [steps: [:raw_request, :raw_response, items: [:contents]]]
        )

      [followup_step] = child_message.steps
      assert followup_step.sequence == 1
      assert followup_step.raw_response == nil
      assert followup_step.input_tokens == nil
      assert followup_step.items == []
      assert child_message.parent_id == nil

      child_chat = Ash.get!(Chat, reference.chat_id, actor: actor)
      assert child_chat.fork_source_step_id == parent.step_id
      assert child_chat.parent_tool_call_item_id == parent.call.item_id
      assert child_chat.fork_task == selected_task
      assert child_chat.note == "Selected branch"
      assert count_messages!(child_chat.id, actor) == 1

      messages = followup_step.raw_request["messages"]
      assistant_message = Enum.find(messages, &(&1["role"] == "assistant"))
      tool_messages = Enum.filter(messages, &(&1["role"] == "tool"))
      call_ids = Enum.map(parent.calls, & &1.call_id)

      assert Enum.map(assistant_message["tool_calls"], & &1["id"]) == call_ids

      assert assistant_message["reasoning_details"] ==
               get_in(parent.raw_response, [
                 "choices",
                 Access.at(0),
                 "message",
                 "reasoning_details"
               ])

      assert Enum.map(tool_messages, & &1["tool_call_id"]) == call_ids

      selected_tool_message =
        Enum.find(tool_messages, &(&1["tool_call_id"] == parent.call.call_id))

      assert selected_tool_message["content"] ==
               "Fork branch initialized. The parent response is complete; follow only the next " <>
                 "user instruction."

      refute String.contains?(selected_tool_message["content"], selected_task)

      assert List.last(messages) == %{
               "role" => "user",
               "content" => ForkBoundary.steering(selected_task)
             }

      send(starter_pid, :continue_parallel_fork)
      assert {:ok, ^reference} = Task.await(starter, 5_000)

      completed = wait_for_status!(reference.generation_message_id, actor, [:done])
      assert completed.error_detail == nil
    end

    test "separate parallel calls prepare independent local roots with no copied provider usage" do
      %{user: actor} = user_fixture()
      parent = parallel_fork_parent!(actor, "Task one", "Task two")
      test_process = self()

      results =
        parent.calls
        |> Task.async_stream(
          fn call ->
            context = tool_call_context(parent, actor, tool_call_item_id: call.item_id)

            Fork.start_or_resume(
              parent.tool_instance,
              call.args["brief"],
              call.args["prompt"],
              context,
              actor,
              on_reference: fn reference ->
                send(test_process, {:linked_prepared, reference})
                {:error, :prepared_only}
              end
            )
          end,
          max_concurrency: 2,
          timeout: :infinity
        )
        |> Enum.to_list()

      assert results == [{:ok, {:error, :prepared_only}}, {:ok, {:error, :prepared_only}}]
      assert_receive {:linked_prepared, first}
      assert_receive {:linked_prepared, second}
      refute first.chat_id == second.chat_id

      for reference <- [first, second] do
        messages =
          ChatMessage
          |> Ash.Query.filter(chat_id == ^reference.chat_id)
          |> Ash.read!(actor: actor, load: [steps: [:raw_request]])

        assert [%ChatMessage{parent_id: nil, steps: [step]}] = messages
        assert step.sequence == 1
        assert is_nil(step.input_tokens)
        assert is_nil(step.output_tokens)
        assert is_nil(step.cost)
        assert Enum.count(step.raw_request["messages"], &(&1["role"] == "tool")) == 2
      end
    end

    test "follows up in the linked child without copying history and keeps its original result" do
      %{user: actor} = user_fixture()
      task = "Return a short delegated answer"
      parent = fork_parent!(actor, task)
      context = tool_call_context(parent, actor)

      assert {:ok, first} = start_or_resume(:fork, parent, context, actor)
      original = wait_for_status!(first.generation_message_id, actor, [:done])
      assert {:ok, original_snapshot} = Fork.snapshot(first, actor)
      assert original_snapshot.status == :completed

      child = Ash.get!(Chat, first.chat_id, actor: actor)
      assert child.fork_source_step_id == parent.step_id
      assert child.fork_task == task
      assert count_messages!(child.id, actor) == 1

      {:ok, _followup} =
        Threads.add_message_to_end(child, :user, "Please expand that answer", actor: actor)

      assert {:ok, followup} = GenerationSupervisor.start_generation(child.id, actor: actor)
      followup_message = wait_for_status!(followup.message_id, actor, [:done])
      assert followup_message.error_detail == nil
      refute followup.message_id == original.id

      assert {:ok, resumed} = start_or_resume(:fork, parent, context, actor)
      assert resumed.generation_message_id == original.id
      assert {:ok, resumed_snapshot} = Fork.snapshot(resumed, actor)
      assert resumed_snapshot.result.text == original_snapshot.result.text

      # Only the child's own turns are physical records. Its parent continues separately.
      assert count_messages!(child.id, actor) == 3

      {:ok, _late_parent} =
        Threads.add_message_to_end(parent.chat, :user, "PARENT_ONLY_FUTURE", actor: actor)

      history =
        IntellectualClub.Generation.Context.history_for_generation!(child.id, actor: actor)

      refute inspect(history) =~ "PARENT_ONLY_FUTURE"
      assert inspect(history) =~ "Please expand that answer"
    end

    test "start_or_resume reuses a completed child and snapshots use an opaque answer cursor" do
      %{user: actor} = user_fixture()
      task = "Inspect completed fork"
      parent = fork_parent!(actor, task)
      child_chat = create_fork_child!(actor, parent, task)

      {:ok, child_message} =
        Threads.add_message_to_end(child_chat, :assistant, "Completed child answer", actor: actor)

      assert {:ok, reference} =
               start_or_resume(:fork, parent, tool_call_context(parent, actor), actor)

      assert reference.chat_id == child_chat.id
      assert reference.generation_message_id == child_message.id

      assert {:ok, first} = Fork.snapshot(reference, actor)
      assert first.status == :completed
      assert [%{type: "answer", text: "Completed child answer", mode: "replace"}] = first.progress
      assert [%{cursor: progress_cursor}] = first.progress
      assert first.url == "/chats/#{child_chat.id}"
      refute Map.has_key?(first, :reasoning)
      assert is_binary(first.next_cursor)
      assert progress_cursor == first.next_cursor
      assert first.result.raw["fork"]["final_message_id"] == child_message.id

      assert {:ok, unchanged} = Fork.snapshot(reference, actor, first.next_cursor)
      assert unchanged.status == :completed
      assert unchanged.progress == []
      assert unchanged.next_cursor == first.next_cursor

      assert {:ok, reset} = Fork.snapshot(reference, actor, "invalid-cursor")
      assert [%{type: "answer", text: "Completed child answer", mode: "replace"}] = reset.progress
      assert [%{cursor: reset_cursor}] = reset.progress
      assert reset_cursor == reset.next_cursor
    end
  end

  describe "spawn" do
    test "creates one empty-context subagent with copied chat settings and spawn metadata" do
      %{user: actor} = user_fixture()
      brief = "  Research a focused question  "
      prompt = "Return a concise independent answer."
      parent = spawn_parent!(actor, brief, prompt)
      configuration = create_configuration!(actor, model_name: "demo", context_length: nil)
      bot = create_bot!(actor, name: "Spawn bot", first_messages: ["Fresh bot greeting"])

      source_chat =
        parent.chat
        |> Ash.Changeset.for_update(
          :update,
          %{bot_id: bot.id, llm_configuration_id: configuration.id},
          actor: actor
        )
        |> Ash.update!(actor: actor)

      knowledge_block =
        create_knowledge_block!(actor, name: "Spawn chat context", content: "Copied chat binding")

      create_chat_block_binding!(actor, source_chat, knowledge_block,
        enabled: false,
        sequence: 17
      )

      [source_tool_binding] = chat_tool_bindings!(actor, source_chat)

      source_tool_binding =
        source_tool_binding
        |> Ash.Changeset.for_update(:update, %{enabled: true, sequence: 9}, actor: actor)
        |> Ash.update!(actor: actor)

      parent = %{parent | chat: source_chat}
      context = tool_call_context(parent, actor)

      assert {:ok, result} =
               Spawn.create_and_run(parent.tool_instance, brief, prompt, context, actor)

      assert %{
               "chat_id" => child_chat_id,
               "prompt_message_id" => prompt_message_id,
               "message_id" => generation_message_id,
               "generation_message_id" => generation_message_id,
               "final_chat_id" => child_chat_id,
               "final_message_id" => generation_message_id
             } = result.raw["spawn"]

      refute Map.has_key?(result.raw, "fork")
      assert subchat_ids_for_call(actor, parent.call.item_id) == [child_chat_id]

      child = Ash.get!(Chat, child_chat_id, actor: actor)
      assert child.note == String.trim(brief)
      assert child.parent_chat_id == parent.chat.id
      assert child.parent_message_id == parent.message.id
      assert child.parent_relation_kind == :spawn
      assert child.subagent == true
      assert child.bot_id == bot.id
      assert child.llm_configuration_id == configuration.id

      assert [] =
               ChatShare |> Ash.Query.filter(chat_id == ^child_chat_id) |> Ash.read!(actor: actor)

      assert chat_binding_settings!(actor, child_chat_id) == %{
               blocks: [{knowledge_block.id, false, 17}],
               tools: [{source_tool_binding.tool_instance_id, true, 9}]
             }

      child_messages = messages_for_chat!(actor, child_chat_id)
      assert Enum.map(child_messages, & &1.role) == [:assistant, :user, :assistant]

      assert Enum.map(Enum.drop(child_messages, 1), & &1.id) == [
               prompt_message_id,
               generation_message_id
             ]

      assert Enum.map(Enum.take(child_messages, 2), &Previews.message_preview_text/1) ==
               ["Fresh bot greeting", prompt]

      refute Enum.any?(child_messages, &(Previews.message_preview_text(&1) == "Spawn now"))

      assert {:ok, same_reference} =
               Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor)

      assert same_reference.chat_id == child_chat_id
      assert same_reference.prompt_message_id == prompt_message_id
      assert same_reference.generation_message_id == generation_message_id
      assert subchat_ids_for_call(actor, parent.call.item_id) == [child_chat_id]
    end

    test "resumes the same prepared generation after a crash before reference persistence" do
      %{user: actor} = user_fixture()
      parent = spawn_parent!(actor, "Recover prepared spawn", "Resume this exact generation.")
      context = tool_call_context(parent, actor)

      assert {:error, {:throw, :simulated_crash}} =
               start_or_resume(:spawn, parent, context, actor,
                 on_reference: fn _reference -> throw(:simulated_crash) end
               )

      [child_chat_id] = subchat_ids_for_call(actor, parent.call.item_id)
      child = Ash.get!(Chat, child_chat_id, actor: actor, load: [:last_message])
      generation_message_id = child.last_message.id
      assert child.last_message.status == :generating
      assert GenerationSupervisor.get_generation_state(generation_message_id) == :not_found

      assert {:ok, reference} = start_or_resume(:spawn, parent, context, actor)
      assert reference.chat_id == child_chat_id
      assert reference.generation_message_id == generation_message_id
      assert subchat_ids_for_call(actor, parent.call.item_id) == [child_chat_id]

      completed = wait_for_status!(generation_message_id, actor, [:done])
      assert completed.error_detail == nil
    end
  end

  describe "fork and spawn" do
    for primitive <- [:fork, :spawn] do
      test "#{primitive} cancels a prepared child when durable reference persistence fails" do
        primitive = unquote(primitive)
        %{user: actor} = user_fixture()
        parent = parent_for!(actor, primitive, "Do not duplicate this generation.")

        assert {:error, :reference_write_failed} =
                 start_or_resume(primitive, parent, tool_call_context(parent, actor), actor,
                   on_reference: fn _reference -> {:error, :reference_write_failed} end
                 )

        [child_chat_id] = subchat_ids_for_call(actor, parent.call.item_id)
        child = Ash.get!(Chat, child_chat_id, actor: actor, load: [:last_message])
        assert child.last_message.status == :canceled
        assert GenerationSupervisor.get_generation_state(child.last_message.id) == :not_found
      end

      test "#{primitive} cannot prepare a child from a stale parent epoch" do
        primitive = unquote(primitive)
        %{user: actor} = user_fixture()
        parent = parent_for!(actor, primitive, "The parent was canceled.")
        assert {:ok, lease} = Lease.acquire(parent.message.id)
        context = tool_call_context(parent, actor, generation_fence_token: lease.fence_token)

        assert :canceled =
                 Persistence.cancel_generating_message!(parent.message.id, error_detail: nil)

        assert :ok = Lease.release(lease)

        assert {:error, :parent_generation_stale} =
                 start_or_resume(primitive, parent, context, actor)

        assert subchat_ids_for_call(actor, parent.call.item_id) == []
      end

      test "background #{primitive} cancel resolves a prepared generation before its reference is stored" do
        primitive = unquote(primitive)
        %{user: actor} = user_fixture()
        parent = parent_for!(actor, primitive, "This generation must never start.")
        context = tool_call_context(parent, actor)

        background_task =
          create_subagent_background_task!(actor, parent, primitive, parent.call.args, :running)

        test_process = self()

        starter =
          Task.async(fn ->
            start_or_resume(primitive, parent, context, actor,
              on_reference: fn reference ->
                send(test_process, {:prepared, self(), reference})

                receive do
                  :continue_start -> :ok
                after
                  5_000 -> {:error, :reference_barrier_timeout}
                end
              end
            )
          end)

        assert_receive {:prepared, starter_pid, reference}, 5_000
        assert reference.chat_id in subchat_ids_for_call(actor, parent.call.item_id)

        assert {:ok, %{"status" => "canceled"}} =
                 BackgroundTasks.cancel(background_task.id, actor.id)

        send(starter_pid, :continue_start)
        assert {:error, :invalid_status} = Task.await(starter, 5_000)
        assert_generation_canceled!(reference.generation_message_id, actor)

        # A later recovery pass finishes the parent but never resumes the child.
        :ok = GenerationSupervisor.recover_orphaned_generations()
        wait_for_status!(parent.message.id, actor, [:done])
        assert_generation_canceled!(reference.generation_message_id, actor)
      end
    end

    for {primitive, launch} <- [fork: :together, spawn: :after_prepared, fork: :released_together] do
      test "concurrent #{primitive} starts reuse one canonical generation and step (#{launch})" do
        primitive = unquote(primitive)
        %{user: actor} = user_fixture()
        parent = parent_for!(actor, primitive, "Run exactly once.")
        context = tool_call_context(parent, actor)
        test_process = self()

        start = fn label ->
          Task.async(fn ->
            start_or_resume(primitive, parent, context, actor,
              on_reference: fn reference ->
                send(test_process, {:start_ready, label, self(), reference})

                receive do
                  {:continue_start, ^label} -> :ok
                after
                  15_000 -> {:error, :start_barrier_timeout}
                end
              end
            )
          end)
        end

        # `:together` and `:released_together` race both starters on creating
        # the child, `:after_prepared` starts the second one once the first has
        # prepared it. Both wait at the reference barrier at the same time; then
        # either the later one finishes first, or (`:released_together`) both
        # race on starting the prepared generation.
        first_starter = start.(:first)
        first_ready = if unquote(launch) == :after_prepared, do: await_start_ready(:first)
        second_starter = start.(:second)
        {first_pid, first_reference} = first_ready || await_start_ready(:first)
        {second_pid, second_reference} = await_start_ready(:second)
        assert second_reference.chat_id == first_reference.chat_id
        assert second_reference.generation_message_id == first_reference.generation_message_id

        if unquote(launch) == :released_together do
          send(second_pid, {:continue_start, :second})
          send(first_pid, {:continue_start, :first})
          assert {:ok, ^second_reference} = Task.await(second_starter, 5_000)
          assert {:ok, ^first_reference} = Task.await(first_starter, 5_000)
          completed = wait_for_status!(first_reference.generation_message_id, actor, [:done])
          assert completed.error_detail == nil
        else
          send(second_pid, {:continue_start, :second})
          assert {:ok, ^second_reference} = Task.await(second_starter, 5_000)
          completed = wait_for_status!(second_reference.generation_message_id, actor, [:done])
          assert completed.error_detail == nil

          send(first_pid, {:continue_start, :first})
          assert {:ok, ^first_reference} = Task.await(first_starter, 5_000)
        end

        assert subchat_ids_for_call(actor, parent.call.item_id) == [first_reference.chat_id]
        wait_for_generation_worker_to_stop!(first_reference.generation_message_id)

        steps =
          ChatMessageStep
          |> Ash.Query.filter(chat_message_id == ^first_reference.generation_message_id)
          |> Ash.Query.sort(sequence: :asc)
          |> Ash.Query.load([:items])
          |> Ash.read!(actor: actor)

        assert Enum.map(steps, &{&1.sequence, &1.status}) == [{1, :done}]
        assert Enum.count(hd(steps).items, &(&1.type == :answer)) == 1
      end
    end
  end

  describe "parent receipt" do
    test "a stale parent epoch cannot persist a receipt after cancellation" do
      %{user: actor} = user_fixture()
      parent = spawn_parent!(actor, "Stale result", "Do not write a result.")
      assert {:ok, lease} = Lease.acquire(parent.message.id)

      try do
        assert :canceled =
                 Persistence.cancel_generating_message!(parent.message.id, error_detail: nil)

        assert {:error, :lease_lost} =
                 persist_parent_receipt(parent, lease, %ExecutionResult{text: "stale"})

        assert parent_tool_results(parent, actor) == []

        assert Ash.get!(ChatMessage, parent.message.id, actor: actor).generation_fence_token ==
                 nil
      after
        Lease.release(lease)
      end
    end

    test "a stale parent writer cannot overwrite a receipt from a replacement epoch" do
      %{user: actor} = user_fixture()
      parent = fork_parent!(actor, "Keep the replacement result")
      assert {:ok, stale_lease} = Lease.acquire(parent.message.id)
      assert :ok = Lease.release(stale_lease)
      assert {:ok, lease} = Lease.acquire(parent.message.id)

      try do
        refute lease.fence_token == stale_lease.fence_token
        stale_result = %ExecutionResult{text: "stale", raw: %{"epoch" => "stale"}}
        result = %ExecutionResult{text: "replacement", raw: %{"epoch" => "replacement"}}

        assert {:error, :lease_lost} = persist_parent_receipt(parent, stale_lease, stale_result)
        assert [missing] = Persistence.list_missing_tool_calls!(parent.step_id)
        assert missing.item_id == parent.call.item_id
        assert {:ok, %ToolResult{} = receipt} = persist_parent_receipt(parent, lease, result)
        assert {:error, :lease_lost} = persist_parent_receipt(parent, stale_lease, stale_result)
        assert :ok = Lease.release(stale_lease)

        message = load_message!(parent.message.id, actor)
        assert message.status == :generating
        assert message.generation_fence_token == lease.fence_token
        assert Lease.valid?(lease)
        assert [persisted] = tool_result_items(message, parent.call.item_id)
        assert persisted.id == receipt.item_id
        assert tool_result_raw(message, parent.call.item_id) == result.raw
        assert History.project_text_for_item_type(message, :tool_result) == result.text
      after
        Lease.release(lease)
      end
    end

    test "a completed parent rejects preparation and fenced receipts with the same live epoch" do
      %{user: actor} = user_fixture()
      parent = spawn_parent!(actor, "Completed parent", "Do not create a child.")
      assert {:ok, lease} = Lease.acquire(parent.message.id)

      try do
        context = tool_call_context(parent, actor, generation_fence_token: lease.fence_token)
        set_message_status!(actor, parent.message, :done, finished_at: DateTime.utc_now())

        completed = Ash.get!(ChatMessage, parent.message.id, actor: actor)
        assert completed.status == :done
        assert completed.generation_fence_token == lease.fence_token
        assert {:ok, :same_epoch} = Lease.with_fence(lease, fn -> :same_epoch end)
        refute Lease.valid?(lease)

        assert {:error, :parent_generation_stale} =
                 start_or_resume(:spawn, parent, context, actor)

        assert {:error, :invalid_status} =
                 persist_parent_receipt(parent, lease, %ExecutionResult{text: "stale"})

        assert subchat_ids_for_call(actor, parent.call.item_id) == []
        assert parent_tool_results(parent, actor) == []
      after
        Lease.release(lease)
      end

      assert Ash.get!(ChatMessage, parent.message.id, actor: actor).generation_fence_token == nil
    end

    test "concurrent parent writers return one canonical receipt on replay" do
      %{user: actor} = user_fixture()
      parent = fork_parent!(actor, "Persist one parent result")
      assert {:ok, lease} = Lease.acquire(parent.message.id)
      writer_supervisor = start_supervised!({Task.Supervisor, []})
      test_process = self()

      result = %ExecutionResult{
        text: "Canonical result",
        raw: %{"fork" => %{"chat_id" => 123, "generation_message_id" => 456}}
      }

      try do
        writers =
          for index <- 1..8 do
            Task.Supervisor.async_nolink(writer_supervisor, fn ->
              send(test_process, {:writer_ready, index, self()})

              receive do
                {:persist, ^index} -> persist_parent_receipt(parent, lease, result)
              after
                5_000 -> {:error, :write_barrier_timeout}
              end
            end)
          end

        ready =
          for _index <- 1..8 do
            assert_receive {:writer_ready, index, pid}, 5_000
            {index, pid}
          end

        Enum.each(ready, fn {index, pid} -> send(pid, {:persist, index}) end)

        receipts =
          Enum.map(writers, fn writer ->
            assert {:ok, %ToolResult{} = receipt} = Task.await(writer, 5_000)
            receipt
          end)

        assert [receipt_id] = receipts |> Enum.map(& &1.item_id) |> Enum.uniq()
        assert [responses_item] = receipts |> Enum.map(& &1.responses_item) |> Enum.uniq()
        assert Enum.all?(receipts, &(&1.tool_call_item_id == parent.call.item_id))

        assert {:ok, replay} =
                 persist_parent_receipt(parent, lease, %ExecutionResult{
                   text: "Replay must not replace the canonical receipt",
                   raw: %{"different" => true}
                 })

        assert replay.item_id == receipt_id
        assert replay.responses_item == responses_item
        assert replay.text == result.text
        assert replay.result_raw == result.raw
        assert Persistence.list_missing_tool_calls!(parent.step_id) == []

        parent_message = load_message!(parent.message.id, actor)
        assert [persisted] = tool_result_items(parent_message, parent.call.item_id)
        assert persisted.id == receipt_id
        assert tool_result_raw(parent_message, parent.call.item_id) == result.raw
      after
        Lease.release(lease)
      end
    end
  end

  describe "background subagents" do
    test "fork_background completes through the durable task adapter while its worker waits" do
      gate_generations!()
      %{user: actor} = user_fixture()
      configuration = create_gated_configuration!(actor)
      task = "Complete in the background"
      parent = fork_parent!(actor, task, chat: %{llm_configuration_id: configuration.id})

      assert {:ok, launch} =
               NativeAgentManagement.execute(
                 parent.tool_instance,
                 "fork_background",
                 %{"brief" => "  Background summary  ", "prompt" => "  " <> task <> "  "},
                 tool_call_context(parent, actor)
               )

      task_id = launch.raw["background_task_id"]
      assert is_binary(task_id)
      gate = await_gated_generation!()
      assert_event_driven_background_wait!(task_id)
      assert_in_flight_snapshot!(task_id, actor)
      release_gated_generation(gate)

      snapshot = wait_for_background_snapshot!(task_id, actor.id, "completed")
      assert is_integer(snapshot["target_chat_id"])
      child_chat = Ash.get!(Chat, snapshot["target_chat_id"], actor: actor)
      assert child_chat.note == "Background summary"
      assert child_chat.fork_task == task
      envelope = Ash.get!(BackgroundTask, task_id, actor: actor)
      assert envelope.arguments == %{"brief" => "Background summary", "prompt" => task}
      assert get_in(snapshot, ["result", "raw", "fork", "chat_id"]) == snapshot["target_chat_id"]

      generation_message_id = snapshot["runner_ref"]["fork_generation_message_id"]

      assert generation_message_id ==
               get_in(snapshot, ["result", "raw", "fork", "generation_message_id"])

      assert snapshot["runner_ref"]["fork_message_id"] == generation_message_id
      assert is_binary(snapshot["next_cursor"])
      assert Enum.all?(snapshot["progress"], &(&1["type"] == "answer"))

      {:ok, later_message} =
        Threads.add_message_to_end(child_chat, :assistant, "Unrelated later answer", actor: actor)

      refute later_message.id == generation_message_id

      # The durable reference pins the snapshot to the original generation.
      assert {:ok, stable} = BackgroundTasks.snapshot(task_id, "invalid-cursor", actor.id)

      refute Enum.any?(
               stable["progress"],
               &String.contains?(&1["text"], "Unrelated later answer")
             )

      assert {:ok, unchanged} =
               BackgroundTasks.snapshot(task_id, snapshot["next_cursor"], actor.id)

      assert unchanged["status"] == "completed"
      assert unchanged["progress"] == []
    end

    test "spawn_background persists spawn refs and completes through its adapter while its worker waits" do
      gate_generations!()
      # A paced demo stream (1 ms per chunk) after the gate.
      put_app_env(:demo_chunk_delay_ms, 1)
      %{user: actor} = user_fixture()
      configuration = create_gated_configuration!(actor)
      brief = "Background spawn"
      prompt = "Complete independently."

      parent =
        create_parent_call!(actor, :spawn, %{"brief" => brief, "prompt" => prompt},
          chat: %{llm_configuration_id: configuration.id}
        )

      assert {:ok, launch} =
               BackgroundTasks.start_spawn(
                 parent.tool_instance,
                 brief,
                 prompt,
                 tool_call_context(parent, actor)
               )

      task_id = launch.raw["background_task_id"]
      gate = await_gated_generation!()
      assert_event_driven_background_wait!(task_id)
      assert_in_flight_snapshot!(task_id, actor)
      release_gated_generation(gate)

      snapshot = wait_for_background_snapshot!(task_id, actor.id, "completed")
      assert snapshot["kind"] == "spawn"
      assert is_integer(snapshot["target_chat_id"])
      assert snapshot["runner_ref"]["spawn_chat_id"] == snapshot["target_chat_id"]
      assert is_integer(snapshot["runner_ref"]["spawn_prompt_message_id"])

      assert snapshot["runner_ref"]["spawn_generation_message_id"] ==
               get_in(snapshot, ["result", "raw", "spawn", "generation_message_id"])

      assert get_in(snapshot, ["result", "raw", "spawn", "chat_id"]) == snapshot["target_chat_id"]
    end

    test "durable background spawn is rejected after its parent generation is canceled" do
      %{user: actor} = user_fixture()
      brief = "Detached spawn"
      prompt = "Finish after the parent is canceled."
      parent = spawn_parent!(actor, brief, prompt)
      assert {:ok, lease} = Lease.acquire(parent.message.id)

      background_task =
        create_subagent_background_task!(actor, parent, :spawn, parent.call.args, :running,
          generation_fence_token: lease.fence_token
        )

      assert :canceled = QueueCoordinator.cancel_generation(parent.message.id, error_detail: nil)
      assert :ok = Lease.release(lease)
      assert wait_for_background_snapshot!(background_task.id, actor.id, "canceled")
      context = BackgroundTasks.execution_context(background_task)
      assert context.generation_fence_token != nil

      assert {:error, _reason} =
               Spawn.execute_background(
                 background_task,
                 parent.tool_instance,
                 "spawn",
                 %{"brief" => brief, "prompt" => prompt},
                 context
               )

      assert subchat_ids_for_call(actor, parent.call.item_id) == []
    end

    test "background fork cancels its generation when the waiter cannot snapshot its reference" do
      %{user: actor} = user_fixture()
      task = "Lose the durable fork reference"
      parent = fork_parent!(actor, task)
      child_chat = create_fork_child!(actor, parent, task)
      child_message = create_generating_message!(actor, child_chat, step: :waiting_provider)

      invalid_reference = %{
        chat_id: parent.chat.id,
        message_id: child_message.id,
        generation_message_id: child_message.id,
        url: "/chats/#{child_chat.id}"
      }

      assert {:error, :invalid_fork_reference} =
               Fork.await_background_snapshot(invalid_reference, actor)

      assert_generation_canceled!(child_message.id, actor)
    end

    @tag :whitebox
    test "background fork authority locks the chat before the lifecycle message and task" do
      %{user: actor} = user_fixture()
      parent = fork_parent!(actor, "Check lock ordering")
      task = create_subagent_background_task!(actor, parent, :fork, parent.call.args, :running)
      context = tool_call_context(parent, actor)

      {result, capture} =
        SqlCapture.measure(fn ->
          BackgroundTasks.with_active_task_authority(task, context, fn -> :ok end)
        end)

      assert result == :ok

      assert [chat_query, message_query, task_query | _rest] =
               Enum.filter(capture.queries, &(&1.sql =~ ~r/FOR (NO KEY )?UPDATE/))

      assert {chat_query.source, message_query.source, task_query.source} ==
               {"chats", "chat_messages", "background_tasks"}
    end
  end

  defp fork_parent!(actor, task, opts \\ []) do
    create_parent_call!(
      actor,
      :fork,
      %{"brief" => "Fork summary", "prompt" => task},
      Keyword.put_new(opts, :user_prompt, "Fork now")
    )
  end

  defp spawn_parent!(actor, brief, prompt) do
    create_parent_call!(actor, :spawn, %{"brief" => brief, "prompt" => prompt},
      user_prompt: "Spawn now"
    )
  end

  defp parent_for!(actor, :fork, prompt), do: fork_parent!(actor, prompt)
  defp parent_for!(actor, :spawn, prompt), do: spawn_parent!(actor, "Spawn summary", prompt)

  defp start_or_resume(primitive, parent, context, actor, opts \\ []) do
    module = if primitive == :fork, do: Fork, else: Spawn
    %{"brief" => brief, "prompt" => prompt} = parent.call.args
    module.start_or_resume(parent.tool_instance, brief, prompt, context, actor, opts)
  end

  defp await_start_ready(label) do
    assert_receive {:start_ready, ^label, pid, reference}, 5_000
    {pid, reference}
  end

  defp persist_parent_receipt(parent, lease, result) do
    persist_receipt(lease, parent.message.id, parent.step_id, parent.call, result)
  end

  defp create_fork_child!(actor, parent, task) do
    create_empty_chat!(actor,
      note: task,
      parent_chat_id: parent.chat.id,
      parent_message_id: parent.message.id,
      parent_tool_call_item_id: parent.call.item_id,
      parent_relation_kind: :fork,
      subagent: true
    )
  end

  # Two fork calls in one provider response that carries reasoning details and
  # interaction steps, as Gemini-style providers return them.
  defp parallel_fork_parent!(actor, sibling_task, selected_task) do
    chat = create_chat!(actor)
    tool_instance = create_tool_instance!(actor, type: "native-agent-management")
    create_tool_function!(actor, tool_instance, name: "fork", parameters_schema: %{})
    create_chat_tool_binding!(actor, chat, tool_instance)
    message = create_generating_message!(actor, chat, user_text: "Fork two branches")

    raw_request = %{
      "model" => "demo-model",
      "messages" => [%{"role" => "user", "content" => "Fork two branches"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(message.id, 1, raw_request, [])

    call_specs = [
      {"fork_#{System.unique_integer([:positive])}", sibling_task, 1},
      {"fork_#{System.unique_integer([:positive])}", selected_task, 2}
    ]

    args = fn task -> %{"brief" => "Fork summary", "prompt" => task} end

    raw_response = %{
      "steps" =>
        Enum.map(call_specs, fn {call_id, task, sequence} ->
          %{
            "type" => "function_call",
            "id" => call_id,
            "name" => "agent_management__fork",
            "arguments" => args.(task)
          }
          |> then(&if(sequence == 1, do: Map.put(&1, "signature", "batch-signature"), else: &1))
        end),
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "",
            "reasoning_details" => [
              %{
                "type" => "reasoning.encrypted",
                "format" => "google-gemini-v1",
                "data" => "opaque-reasoning-signature"
              }
            ],
            "tool_calls" =>
              Enum.map(call_specs, fn {call_id, task, _sequence} ->
                %{
                  "id" => call_id,
                  "type" => "function",
                  "function" => %{
                    "name" => "agent_management__fork",
                    "arguments" => Jason.encode!(args.(task))
                  }
                }
              end)
          }
        }
      ]
    }

    runtime_step =
      call_specs
      |> Enum.reduce(
        RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request),
        fn {call_id, task, sequence}, step ->
          add_runtime_tool_call(step, call_id, "agent_management__fork", args.(task), sequence)
        end
      )
      |> RuntimeTrace.apply_event({:set_step_raw_response, raw_response})
      |> RuntimeTrace.apply_event({:set_step_response_final, true})

    %{tool_calls: calls} = Persistence.persist_provider_completed!(message.id, runtime_step)
    {selected_call_id, _task, _sequence} = List.last(call_specs)

    %{
      chat: chat,
      message: message,
      step_id: step_id,
      call: Enum.find(calls, &(&1.call_id == selected_call_id)),
      calls: calls,
      raw_response: raw_response,
      tool_instance: tool_instance
    }
  end

  defp wait_for_status!(message_id, actor, wanted) do
    wait_for_message_status!(message_id, actor, wanted,
      timeout: 6_000,
      load: [steps: [items: [:contents]]],
      stop_worker: true
    )
  end

  defp assert_generation_canceled!(message_id, actor) do
    assert Ash.get!(ChatMessage, message_id, actor: actor).status == :canceled
    assert GenerationSupervisor.get_generation_state(message_id) == :not_found
  end

  defp load_message!(message_id, actor) do
    Ash.get!(ChatMessage, message_id, actor: actor, load: [steps: [items: [:contents]]])
  end

  defp count_messages!(chat_id, actor) do
    ChatMessage |> Ash.Query.filter(chat_id == ^chat_id) |> Ash.count!(actor: actor)
  end

  defp parent_tool_results(parent, actor) do
    ChatMessageItem
    |> Ash.Query.filter(chat_message_step_id == ^parent.step_id and type == :tool_result)
    |> Ash.read!(actor: actor)
  end

  # While the child generation is held by the gate the task is running and its
  # snapshot is resolved against the live generation process.
  #
  # NOTE: the live runtime step reaches `Subagent` in its client-normalized form
  # (string item types), so the partial answer is not part of `progress` yet;
  # see the stage 2 report.
  defp assert_in_flight_snapshot!(task_id, actor) do
    assert {:ok, snapshot} = BackgroundTasks.snapshot(task_id, nil, actor.id)
    assert snapshot["status"] == "running"
    assert snapshot["result"] == nil
  end

  # The worker must wait on the generation process (monitor), not poll it from
  # an execution task.
  defp assert_event_driven_background_wait!(task_id) do
    wait_until(
      fn ->
        with [{worker_pid, _value}] <-
               Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task_id),
             %{} = state <- safe_worker_state(worker_pid) do
          execution_children =
            Task.Supervisor.children(IntellectualClub.BackgroundTasks.ExecutionSupervisor)

          state.waiting? == true and is_nil(state.execution_task) and
            is_pid(state.generation_pid) and is_reference(state.generation_monitor_ref) and
            worker_pid not in execution_children
        else
          _other -> false
        end
      end,
      timeout: 5_000,
      message: "Background worker #{task_id} did not wait on its generation"
    )
  end

  defp safe_worker_state(worker_pid) do
    :sys.get_state(worker_pid)
  catch
    :exit, _reason -> nil
  end
end
