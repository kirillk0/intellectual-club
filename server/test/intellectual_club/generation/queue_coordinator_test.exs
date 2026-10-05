defmodule IntellectualClub.Generation.QueueCoordinatorTest do
  @moduledoc """
  The per-chat FIFO of queued follow-ups and steers: delivery as new turns,
  blocking and reopening at terminal generation boundaries, conversion of late
  steers, and transfer of the backlog across handoffs.
  """
  use IntellectualClub.DataCase, async: false

  require Ash.Query

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep, QueuedMessages, Threads}
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.{QueueCoordinator, QueueDispatcher, StepRequests, Worker}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Notifications.WebPushGenerationEvent
  alias IntellectualClub.Test.GenerationRuntime.Barrier

  describe "follow-up delivery" do
    test "atomically delivers a follow-up and transfers its file into canonical contents" do
      %{user: actor} = user_fixture()
      {chat, _root, anchor} = create_chat_with_anchor!(actor)
      {:ok, file} = Files.create_from_binary("queued.txt", "text/plain", "queued payload")

      assert {:ok, queued} =
               QueuedMessages.enqueue_follow_up(
                 chat.id,
                 %{content: "Queued text", file_ids: [file.id]},
                 actor
               )

      assert {:ok, context} = QueueCoordinator.prepare_next(chat.id)
      assert context.chat_id == chat.id

      assert {:ok, delivered} = QueuedMessages.get(queued.id, actor)
      assert delivered.status == :delivered
      assert delivered.anchor_message_id == anchor.id
      assert delivered.assistant_message_id == context.message_id
      assert delivered.contents == []

      user_message = load_message_trace!(delivered.user_message_id, actor)
      assert user_message.parent_id == anchor.id

      assert [text, media] = canonical_contents(user_message)
      assert text.kind == :text
      assert text.content_text == "Queued text"
      assert media.kind == :media
      assert media.file_id == file.id

      assert {:ok, {persisted_file, "queued payload"}} = Files.load_payload(file.id)
      assert persisted_file.id == media.file_id

      generated = Ash.get!(ChatMessage, context.message_id, actor: actor)
      assert generated.parent_id == user_message.id
      assert generated.status == :generating
    end

    test "delivers three follow-ups as three strictly ordered turns" do
      %{user: actor} = user_fixture()
      {chat, _root, anchor} = create_chat_with_anchor!(actor)

      queued =
        for content <- ["First", "Second", "Third"] do
          assert {:ok, queued_message} =
                   QueuedMessages.enqueue_follow_up(chat.id, %{content: content}, actor)

          queued_message
        end

      {_parent, contexts} =
        Enum.zip(queued, ["First", "Second", "Third"])
        |> Enum.reduce({anchor, []}, fn {queued_message, expected_text}, {parent, contexts} ->
          assert {:ok, context} = QueueCoordinator.prepare_next(chat.id)
          assert {:ok, delivered} = QueuedMessages.get(queued_message.id, actor)
          assert delivered.status == :delivered

          user_message = load_message_trace!(delivered.user_message_id, actor)
          assert user_message.parent_id == parent.id
          assert canonical_text(user_message) == expected_text

          generated = Ash.get!(ChatMessage, context.message_id, actor: actor)
          assert generated.parent_id == user_message.id

          set_generation_status!(generated, :done, actor)

          assert {:ok, %{status: :done, converted_steers: 0}} =
                   QueueCoordinator.settle_generation(generated.id, :done)

          {generated, contexts ++ [context]}
        end)

      assert length(contexts) == 3
      assert Enum.uniq(Enum.map(contexts, & &1.message_id)) == Enum.map(contexts, & &1.message_id)
      assert :empty = QueueCoordinator.prepare_next(chat.id)

      assert Enum.all?(queued, fn queued_message ->
               match?({:ok, %{status: :delivered}}, QueuedMessages.get(queued_message.id, actor))
             end)
    end

    test "concurrent prepare calls materialize only one assistant turn" do
      %{user: actor} = user_fixture()
      {chat, _root, anchor} = create_chat_with_anchor!(actor)

      assert {:ok, queued} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "Exactly once"}, actor)

      results =
        1..2
        |> Task.async_stream(
          fn _index -> QueueCoordinator.prepare_next(chat.id) end,
          max_concurrency: 2,
          ordered: false,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      contexts = for {:ok, context} <- results, do: context
      assert [context] = contexts
      assert Enum.count(results, &(&1 == :active)) == 1

      assert {:ok, delivered} = QueuedMessages.get(queued.id, actor)
      assert delivered.status == :delivered
      assert delivered.assistant_message_id == context.message_id

      queue_users =
        chat.id
        |> Threads.all_messages(actor)
        |> Enum.filter(&(&1.role == :user and &1.parent_id == anchor.id))

      assert [%ChatMessage{id: user_message_id}] = queue_users
      assert user_message_id == delivered.user_message_id

      generating_assistants =
        chat.id
        |> Threads.all_messages(actor)
        |> Enum.filter(&(&1.role == :assistant and &1.status == :generating))

      assert [%ChatMessage{id: generated_id}] = generating_assistants
      assert generated_id == context.message_id
    end

    test "branch changes pause the queue and send-next reanchors it to the active branch" do
      %{user: actor} = user_fixture()
      {chat, root, old_anchor} = create_chat_with_anchor!(actor)

      assert {:ok, first} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "Continue here"}, actor)

      assert {:ok, second} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "Then this"}, actor)

      assert {:ok, active_branch} =
               Threads.add_message(chat, :assistant, "Alternative answer",
                 actor: actor,
                 parent_id: root.id
               )

      assert active_branch.id != old_anchor.id
      assert {:blocked, :branch_changed} = QueueCoordinator.prepare_next(chat.id)

      assert {:ok, blocked_first} = QueuedMessages.get(first.id, actor)
      assert {:ok, blocked_second} = QueuedMessages.get(second.id, actor)
      assert blocked_first.status == :blocked
      assert blocked_second.status == :blocked
      assert blocked_first.blocked_reason == "branch_changed"
      assert blocked_second.blocked_reason == "branch_changed"

      assert {:ok, resumed} = QueuedMessages.send_next(first.id, actor)
      assert resumed.status == :pending
      assert resumed.anchor_message_id == active_branch.id

      assert {:ok, reanchored_second} = QueuedMessages.get(second.id, actor)
      assert reanchored_second.anchor_message_id == active_branch.id

      assert {:ok, _context} = QueueCoordinator.prepare_next(chat.id)
      assert {:ok, delivered} = QueuedMessages.get(first.id, actor)

      user_message = Ash.get!(ChatMessage, delivered.user_message_id, actor: actor)
      assert user_message.parent_id == active_branch.id
    end

    test "Done fallback starts the prepared worker when the dispatcher is unavailable" do
      %{user: actor} = user_fixture()
      {chat, _root, _anchor} = create_chat_with_anchor!(actor)
      generation = create_generating_assistant!(chat, actor)

      assert {:ok, _queued} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "Fallback follow-up"}, actor)

      set_generation_status!(generation, :done, actor)

      :ok = Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

      put_app_env(:demo_chunk_delay_ms, 1_000)

      assert {:advanced, next_message_id} =
               without_registered_dispatcher(fn ->
                 QueueDispatcher.generation_finished(generation.id, :done)
               end)

      # Child startup does not acknowledge the asynchronous initialization.
      assert_receive {:content_delta, ^next_message_id, _delta}, 5_000
      assert {:ok, _poll} = GenerationSupervisor.poll_generation(next_message_id)
      stop_generation_worker!(next_message_id)
    end

    test "an ordinary parent callback error rolls back its mutations" do
      %{user: actor} = user_fixture()
      {chat, _root, anchor} = create_chat_with_anchor!(actor)

      assert {:error, :parent_rejected} =
               QueueCoordinator.prepare_direct_generation(chat.id, [actor: actor], fn ->
                 {:ok, _user} =
                   Threads.add_message_to_end(chat, :user, "Must not survive", actor: actor)

                 {:error, :parent_rejected}
               end)

      assert length(Threads.all_messages(chat.id, actor)) == 2
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == anchor.id
    end
  end

  describe "unlocked preparation" do
    test "editing the FIFO head during unlocked preparation publishes only the new contents" do
      %{user: actor} = user_fixture()
      {chat, _root, anchor} = create_chat_with_anchor!(actor)

      assert {:ok, queued} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "Old text"}, actor)

      {task, preparation} = pause_preparation(chat.id)

      assert {:ok, _updated} = QueuedMessages.update(queued.id, %{content: "Edited text"}, actor)
      Barrier.release(preparation)
      assert {:ok, context} = Task.await(task, 15_000)

      assert {:ok, delivered} = QueuedMessages.get(queued.id, actor)
      assert delivered.status == :delivered
      assert delivered.user_message_id == context.parent_message_id
      user = load_message_trace!(delivered.user_message_id, actor)
      assert user.parent_id == anchor.id
      assert canonical_text(user) == "Edited text"
      assert List.last(context.history) == %{role: :user, content: "Edited text"}
      assert length(Threads.all_messages(chat.id, actor)) == 4
    end

    test "canceling the FIFO head during unlocked preparation creates no generation" do
      %{user: actor} = user_fixture()
      {chat, _root, anchor} = create_chat_with_anchor!(actor)

      assert {:ok, queued} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "Cancel me"}, actor)

      {task, preparation} = pause_preparation(chat.id)

      assert {:ok, _canceled} = QueuedMessages.cancel(queued.id, actor)
      Barrier.release(preparation)
      assert :empty = Task.await(task, 15_000)
      assert {:ok, %{status: :canceled}} = QueuedMessages.get(queued.id, actor)
      assert length(Threads.all_messages(chat.id, actor)) == 2
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == anchor.id
    end

    test "direct generation cannot bypass a queue whose request is being prepared" do
      %{user: actor} = user_fixture()
      {chat, _root, _anchor} = create_chat_with_anchor!(actor)

      assert {:ok, _queued} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "First"}, actor)

      {task, preparation} = pause_preparation(chat.id)

      assert {:error, :queue_not_empty} =
               QueueCoordinator.prepare_direct_generation(chat.id, actor: actor)

      Barrier.release(preparation)
      assert {:ok, _context} = Task.await(task, 15_000)
      assert length(Threads.all_messages(chat.id, actor)) == 4
    end
  end

  describe "terminal boundaries" do
    for {terminal_status, expected_reason} <- [
          error: "generation_error",
          canceled: "generation_canceled"
        ] do
      @tag terminal_status: terminal_status, expected_reason: expected_reason
      test "#{terminal_status} blocks the backlog until a later Done reopens it",
           %{terminal_status: terminal_status, expected_reason: expected_reason} do
        %{user: actor} = user_fixture()
        {chat, _root, _anchor} = create_chat_with_anchor!(actor)
        generation = create_generating_assistant!(chat, actor)

        assert {:ok, queued} =
                 QueuedMessages.enqueue_follow_up(chat.id, %{content: "After retry"}, actor)

        set_generation_status!(generation, terminal_status, actor)

        assert {:blocked, %{status: ^terminal_status}} =
                 QueueDispatcher.generation_finished(generation.id, terminal_status)

        assert {:ok, blocked} = QueuedMessages.get(queued.id, actor)
        assert blocked.status == :blocked
        assert blocked.blocked_reason == expected_reason
        assert {:blocked, ^expected_reason} = QueueCoordinator.prepare_next(chat.id)

        set_generation_status!(generation, :generating, actor)
        set_generation_status!(generation, :done, actor)

        assert {:ok, %{status: :done, affected_follow_ups: 1}} =
                 QueueCoordinator.settle_generation(generation.id, :done)

        assert {:ok, reopened} = QueuedMessages.get(queued.id, actor)
        assert reopened.status == :pending
        assert reopened.blocked_reason == nil
        assert {:ok, _context} = QueueCoordinator.prepare_next(chat.id)
      end
    end

    test "cancel_generation atomically cancels the assistant, blocks its queue, and records an event" do
      %{user: actor} = user_fixture()
      {chat, _root, _anchor} = create_chat_with_anchor!(actor)
      generation = create_generating_assistant!(chat, actor)
      background_task = create_background_task!(actor, generation: generation)

      assert {:ok, queued} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "After cancellation"}, actor)

      assert :not_generating =
               QueueCoordinator.cancel_generation(generation.id,
                 expected_fence_token: {:expected, "stale-fence"}
               )

      assert Ash.get!(ChatMessage, generation.id, actor: actor).status == :generating
      assert {:ok, %{status: :pending}} = QueuedMessages.get(queued.id, actor)
      assert [] == canceled_events_for(generation.id, actor)

      assert :canceled = QueueCoordinator.cancel_generation(generation.id)

      canceled = Ash.get!(ChatMessage, generation.id, actor: actor)
      assert canceled.status == :canceled
      assert canceled.finished_at

      assert {:ok, blocked} = QueuedMessages.get(queued.id, actor)
      assert blocked.status == :blocked
      assert blocked.blocked_reason == "generation_canceled"

      assert [%WebPushGenerationEvent{suppressed: true, delivered_count: 0}] =
               canceled_events_for(generation.id, actor)

      assert wait_for_background_task_status!(background_task.id, actor, :canceled).cancel_requested ==
               true
    end

    test "fail_generation atomically fails the assistant, blocks its queue, and records an event" do
      %{user: actor} = user_fixture()
      {chat, _root, _anchor} = create_chat_with_anchor!(actor)
      generation = create_generating_assistant!(chat, actor)
      background_task = create_background_task!(actor, generation: generation)

      assert {:ok, queued} =
               QueuedMessages.enqueue_follow_up(chat.id, %{content: "After failure"}, actor)

      assert :failed =
               QueueCoordinator.fail_generation(generation.id,
                 error_detail: "Orphaned generation (worker not found)"
               )

      failed = Ash.get!(ChatMessage, generation.id, actor: actor)
      assert failed.status == :error
      assert failed.error_detail == "Orphaned generation (worker not found)"
      assert failed.finished_at

      assert {:ok, blocked} = QueuedMessages.get(queued.id, actor)
      assert blocked.status == :blocked
      assert blocked.blocked_reason == "generation_error"

      assert [%WebPushGenerationEvent{suppressed: false}] =
               terminal_events_for(generation.id, :error, actor)

      assert [] == canceled_events_for(generation.id, actor)
      assert :not_generating = QueueCoordinator.fail_generation(generation.id)

      assert wait_for_background_task_status!(background_task.id, actor, :canceled).cancel_requested ==
               true
    end

    for terminal_status <- [:done, :error, :canceled] do
      @tag terminal_status: terminal_status
      test "a #{terminal_status} boundary cancels active background tasks only",
           %{terminal_status: terminal_status} do
        %{user: actor} = user_fixture()
        {chat, _root, _anchor} = create_chat_with_anchor!(actor)
        generation = create_generating_assistant!(chat, actor)
        queued = create_background_task!(actor, generation: generation)

        running =
          create_background_task!(actor,
            generation: generation,
            status: :running,
            started_at: DateTime.utc_now()
          )

        completed = create_background_task!(actor, generation: generation)
        assert {:ok, completed} = BackgroundTasks.mark_completed(completed, %{text: "done"})

        {unrelated_chat, _root, _anchor} = create_chat_with_anchor!(actor)
        unrelated_generation = create_generating_assistant!(unrelated_chat, actor)
        unrelated = create_background_task!(actor, generation: unrelated_generation)

        set_generation_status!(generation, terminal_status, actor)

        refute match?(
                 {:error, _reason},
                 QueueDispatcher.generation_finished(generation.id, terminal_status)
               )

        assert wait_for_background_task_status!(queued.id, actor, :canceled).cancel_requested ==
                 true

        assert wait_for_background_task_status!(running.id, actor, :canceled).cancel_requested ==
                 true

        assert %BackgroundTask{status: :completed, cancel_requested: false} =
                 Ash.get!(BackgroundTask, completed.id, actor: actor)

        assert %BackgroundTask{status: :queued, cancel_requested: false} =
                 Ash.get!(BackgroundTask, unrelated.id, actor: actor)
      end
    end

    for cancel_first? <- [true, false] do
      @tag cancel_first?: cancel_first?
      test "cancel_generation leaves a steer enqueued #{if cancel_first?, do: "after", else: "before"} it as a blocked follow-up",
           %{cancel_first?: cancel_first?} do
        %{user: actor} = user_fixture()
        configuration = steering_configuration!(actor)
        {chat, _root, _anchor} = create_chat_with_anchor!(actor, configuration.id)
        generation = create_generating_assistant!(chat, actor, configuration.id)

        if cancel_first?,
          do: assert(:canceled = QueueCoordinator.cancel_generation(generation.id))

        assert {:ok, queued} = QueuedMessages.enqueue_steer(generation.id, "Late steering", actor)

        unless cancel_first?,
          do: assert(:canceled = QueueCoordinator.cancel_generation(generation.id))

        assert {:ok, queued} = QueuedMessages.get(queued.id, actor)
        assert queued.kind == :follow_up
        assert queued.status == :blocked
        assert queued.blocked_reason == "generation_canceled"
        assert queued.anchor_message_id == generation.id
        assert queued.target_generation_message_id == nil
        assert Ash.get!(ChatMessage, generation.id, actor: actor).status == :canceled
      end
    end

    for initial_status <- [:error, :canceled] do
      @tag initial_status: initial_status
      test "retrying a #{initial_status} generation preserves a non-empty backlog and advances one turn",
           %{initial_status: initial_status} do
        %{user: actor} = user_fixture()

        test = self()

        # The retried generation succeeds; the delivered follow-up turn blocks
        # inside the provider until the test releases it.
        {base_url, server} =
          start_scripted_server!(%{
            "/chat/completions" => [
              {200, successful_sse("Recovered answer")},
              {409,
               fn ->
                 send(test, {:blocked_provider_request, self()})

                 receive do
                   :finish -> ["Canceled by test"]
                 after
                   10_000 -> ["Timed out waiting for test"]
                 end
               end}
            ]
          })

        configuration = steering_configuration!(actor, base_url)

        {chat, generation, initial_step} =
          create_generation!(actor, configuration.id, "Retry source")

        assert {:ok, first} =
                 QueuedMessages.enqueue_follow_up(
                   chat.id,
                   %{content: "First after retry"},
                   actor
                 )

        assert {:ok, second} =
                 QueuedMessages.enqueue_follow_up(
                   chat.id,
                   %{content: "Second after retry"},
                   actor
                 )

        set_step_status!(initial_step, initial_status, actor)
        set_generation_status!(generation, initial_status, actor)

        assert {:blocked, %{status: ^initial_status}} =
                 QueueDispatcher.generation_finished(generation.id, initial_status)

        expected_reason = terminal_reason(initial_status)
        assert_queue_state!(first.id, actor, :blocked, expected_reason)
        assert_queue_state!(second.id, actor, :blocked, expected_reason)

        assert {:ok, %{message_id: generation_id}} =
                 GenerationSupervisor.retry_last_step(generation.id,
                   actor: actor,
                   chunk_delay_ms: 0
                 )

        assert generation_id == generation.id

        assert_receive {:blocked_provider_request, blocked_request_pid}, 5_000
        [_retried, request_payload] = scripted_requests(server, "/chat/completions")
        assert Jason.encode!(request_payload) =~ "First after retry"

        retried =
          wait_for_message_status!(generation.id, actor, :done, timeout: 5000, interval: 10)

        assert retried.status == :done
        assert {:error, _error} = Ash.get(ChatMessageStep, initial_step.id, actor: actor)

        assert {:ok, delivered_first} = QueuedMessages.get(first.id, actor)
        assert {:ok, pending_second} = QueuedMessages.get(second.id, actor)

        assert delivered_first.status == :delivered
        assert is_integer(delivered_first.user_message_id)
        assert is_integer(delivered_first.assistant_message_id)
        assert pending_second.status == :pending
        assert pending_second.blocked_reason == nil
        assert pending_second.anchor_message_id == delivered_first.assistant_message_id

        first_user = load_message_trace!(delivered_first.user_message_id, actor)
        assert canonical_text(first_user) == "First after retry"

        assert :ok = GenerationSupervisor.cancel_generation(delivered_first.assistant_message_id)
        send(blocked_request_pid, :finish)

        assert wait_for_message_status!(delivered_first.assistant_message_id, actor, :canceled,
                 timeout: 5000,
                 interval: 10
               ).status ==
                 :canceled

        assert_queue_state!(second.id, actor, :blocked, "generation_canceled")
      end
    end
  end

  describe "late steering" do
    for {terminal_status, expected_status, expected_reason} <- [
          {:done, :pending, nil},
          {:error, :blocked, "generation_error"},
          {:canceled, :blocked, "generation_canceled"}
        ] do
      @tag terminal_status: terminal_status,
           expected_status: expected_status,
           expected_reason: expected_reason
      test "a pending steer that loses the terminal race becomes a follow-up after #{terminal_status}",
           %{
             terminal_status: terminal_status,
             expected_status: expected_status,
             expected_reason: expected_reason
           } do
        %{user: actor} = user_fixture()
        configuration = steering_configuration!(actor, "http://127.0.0.1:9")
        {chat, generation, step} = create_generation!(actor, configuration.id, "Late steer")

        assert {:ok, steer} =
                 QueuedMessages.enqueue_steer(
                   generation.id,
                   %{content: "Continue after terminal result"},
                   actor
                 )

        assert steer.kind == :steer
        assert steer.target_generation_message_id == generation.id
        set_step_status!(step, terminal_status, actor)
        set_generation_status!(generation, terminal_status, actor)

        assert {:ok, %{converted_steers: 1, status: ^terminal_status}} =
                 QueueCoordinator.settle_generation(generation.id, terminal_status)

        assert {:ok, converted} = QueuedMessages.get(steer.id, actor)
        assert converted.kind == :follow_up
        assert converted.status == expected_status
        assert converted.blocked_reason == expected_reason
        assert converted.anchor_message_id == generation.id
        assert converted.target_generation_message_id == nil
        assert converted.steering_item_id == nil

        generation = load_message_trace!(generation.id, actor)
        refute Enum.any?(canonical_items(generation), &(&1.type == :steering))

        case terminal_status do
          :done ->
            assert {:ok, _context} = QueueCoordinator.prepare_next(chat.id)
            assert {:ok, delivered} = QueuedMessages.get(steer.id, actor)
            assert delivered.status == :delivered

            assert canonical_text(load_message_trace!(delivered.user_message_id, actor)) ==
                     "Continue after terminal result"

          status when status in [:error, :canceled] ->
            assert {:blocked, ^expected_reason} = QueueCoordinator.prepare_next(chat.id)
        end
      end
    end

    for {terminal_status, expected_status, expected_reason} <- [
          {:done, :pending, nil},
          {:error, :blocked, "generation_error"},
          {:canceled, :blocked, "generation_canceled"}
        ] do
      @tag terminal_status: terminal_status,
           expected_status: expected_status,
           expected_reason: expected_reason
      test "steer enqueued after #{terminal_status} is created directly as a follow-up",
           %{
             terminal_status: terminal_status,
             expected_status: expected_status,
             expected_reason: expected_reason
           } do
        %{user: actor} = user_fixture()
        configuration = steering_configuration!(actor, "http://127.0.0.1:9")

        {chat, generation, step} =
          create_generation!(actor, configuration.id, "Post-terminal steer")

        set_step_status!(step, terminal_status, actor)
        set_generation_status!(generation, terminal_status, actor)

        assert {:ok, queued_message} =
                 QueuedMessages.enqueue_steer(
                   generation.id,
                   %{content: "Arrived after terminal persistence"},
                   actor
                 )

        assert queued_message.chat_id == chat.id
        assert queued_message.kind == :follow_up
        assert queued_message.status == expected_status
        assert queued_message.blocked_reason == expected_reason
        assert queued_message.anchor_message_id == generation.id
        assert queued_message.target_generation_message_id == nil
        assert queued_message.steering_item_id == nil

        assert QueuedMessages.content_specs(queued_message) == [
                 %{kind: :text, content_text: "Arrived after terminal persistence"}
               ]
      end
    end

    for {terminal_status, expected_status, expected_reason} <- [
          {:done, :delivered, nil},
          {:error, :blocked, "generation_error"},
          {:canceled, :blocked, "generation_canceled"}
        ] do
      @tag terminal_status: terminal_status,
           expected_status: expected_status,
           expected_reason: expected_reason
      test "reconciliation recovers a lone late steer after #{terminal_status}",
           %{
             terminal_status: terminal_status,
             expected_status: expected_status,
             expected_reason: expected_reason
           } do
        %{user: actor} = user_fixture()
        configuration = steering_configuration!(actor, "http://127.0.0.1:9")

        {chat, generation, step} =
          create_generation!(actor, configuration.id, "Recovered late steer")

        assert {:ok, steer} =
                 QueuedMessages.enqueue_steer(
                   generation.id,
                   %{content: "Recover after process loss"},
                   actor
                 )

        set_step_status!(step, terminal_status, actor)
        set_generation_status!(generation, terminal_status, actor)

        assert chat.id in QueueCoordinator.ready_chat_ids()

        case terminal_status do
          :done ->
            assert {:ok, _context} = QueueCoordinator.prepare_next(chat.id)

          status when status in [:error, :canceled] ->
            assert {:blocked, ^expected_reason} = QueueCoordinator.prepare_next(chat.id)
        end

        assert {:ok, recovered} = QueuedMessages.get(steer.id, actor)
        assert recovered.kind == :follow_up
        assert recovered.status == expected_status
        assert recovered.blocked_reason == expected_reason
        assert recovered.target_generation_message_id == nil
        assert recovered.anchor_message_id == generation.id
      end
    end
  end

  describe "handoff" do
    test "handoff fallback starts the first transferred turn in an idle child chat" do
      %{user: actor} = user_fixture()
      {source_chat, _source_root, source_message} = create_chat_with_anchor!(actor)
      {child_chat, _child_root, _child_anchor} = create_chat_with_anchor!(actor)

      assert {:ok, queued} =
               QueuedMessages.enqueue_follow_up(
                 source_chat.id,
                 %{content: "Transferred follow-up"},
                 actor
               )

      :ok = Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{child_chat.id}")

      put_app_env(:demo_chunk_delay_ms, 1_000)

      assert {:transferred, %{transferred_count: 1, dispatch: {:advanced, child_generation_id}}} =
               without_registered_dispatcher(fn ->
                 QueueDispatcher.handoff(source_message.id, child_chat.id, nil)
               end)

      assert {:ok, delivered} = QueuedMessages.get(queued.id, actor)
      assert delivered.chat_id == child_chat.id
      assert delivered.status == :delivered
      assert delivered.assistant_message_id == child_generation_id
      assert_receive {:content_delta, ^child_generation_id, _delta}, 5_000
      assert {:ok, _poll} = GenerationSupervisor.poll_generation(child_generation_id)
      stop_generation_worker!(child_generation_id)
    end

    test "terminal handoff publishes the child step and backlog together without starting a worker" do
      %{user: actor} = user_fixture()
      {source, _root, _anchor} = create_chat_with_anchor!(actor)
      generation = create_generating_assistant!(source, actor)

      assert {:ok, queued} =
               QueuedMessages.enqueue_follow_up(source.id, %{content: "After handoff"}, actor)

      set_generation_status!(generation, :done, actor)

      child =
        Chat
        |> Ash.Changeset.for_create(
          :create_empty,
          %{
            note: "",
            parent_chat_id: source.id,
            parent_message_id: generation.id,
            parent_relation_kind: :handoff
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, summary} = Threads.add_message_to_end(child, :user, "Handoff summary", actor: actor)

      assert {:ok, result} = QueueCoordinator.prepare_terminal_handoff(generation.id, child.id)
      context = result.prepared_context
      assert context.parent_message_id == summary.id
      assert result.child_generation_message_id == context.message_id
      assert result.transferred_count == 1

      assert StepRequests.request_for_step!(context.step_id, actor: actor) ==
               context.request_payload

      assert GenerationSupervisor.get_generation_state(context.message_id) == :not_found
      assert {:ok, moved} = QueuedMessages.get(queued.id, actor)
      assert moved.chat_id == child.id
      assert moved.anchor_message_id == context.message_id
      assert moved.status == :pending

      assert {:ok, resumed} = QueueCoordinator.prepare_terminal_handoff(generation.id, child.id)
      assert resumed.prepared_context == nil
      assert resumed.child_generation_message_id == context.message_id
      assert length(Threads.all_messages(child.id, actor)) == 2
    end

    test "handoff moves a late steer behind the existing backlog and waits for the child generation" do
      %{user: actor} = user_fixture()
      configuration = steering_configuration!(actor, "http://127.0.0.1:9")

      {source_chat, source_generation, source_step} =
        create_generation!(actor, configuration.id, "Source generation")

      assert {:ok, first} =
               QueuedMessages.enqueue_follow_up(
                 source_chat.id,
                 %{content: "Existing follow-up"},
                 actor
               )

      assert {:ok, late_steer} =
               QueuedMessages.enqueue_steer(
                 source_generation.id,
                 %{content: "Late handoff steer"},
                 actor
               )

      {child_chat, child_generation, child_step} =
        create_generation!(actor, configuration.id, "Handoff child",
          parent_chat_id: source_chat.id,
          parent_message_id: source_generation.id,
          parent_relation_kind: :handoff,
          subagent: true
        )

      set_step_status!(source_step, :done, actor)
      set_generation_status!(source_generation, :done, actor)

      assert {:ok, %{transferred_count: 2}} =
               QueueCoordinator.transfer_to_handoff(
                 source_generation.id,
                 child_chat.id,
                 child_generation.id
               )

      assert {:ok, []} = QueuedMessages.list_for_chat(source_chat.id, actor)
      assert {:ok, transferred} = QueuedMessages.list_for_chat(child_chat.id, actor)
      assert Enum.map(transferred, & &1.id) == [first.id, late_steer.id]

      assert {:ok, transferred_first} = QueuedMessages.get(first.id, actor)
      assert {:ok, transferred_steer} = QueuedMessages.get(late_steer.id, actor)

      assert transferred_first.kind == :follow_up
      assert transferred_first.anchor_message_id == child_generation.id
      assert transferred_steer.kind == :follow_up
      assert transferred_steer.status == :pending
      assert transferred_steer.anchor_message_id == child_generation.id
      assert transferred_steer.target_generation_message_id == nil

      assert QueuedMessages.content_specs(transferred_steer) == [
               %{kind: :text, content_text: "Late handoff steer"}
             ]

      assert :active = QueueCoordinator.prepare_next(child_chat.id)

      set_step_status!(child_step, :done, actor)
      set_generation_status!(child_generation, :done, actor)

      assert {:ok, %{status: :done}} =
               QueueCoordinator.settle_generation(child_generation.id, :done)

      assert {:ok, next_context} = QueueCoordinator.prepare_next(child_chat.id)
      assert {:ok, delivered_first} = QueuedMessages.get(first.id, actor)
      assert {:ok, pending_steer} = QueuedMessages.get(late_steer.id, actor)

      assert delivered_first.status == :delivered
      assert delivered_first.assistant_message_id == next_context.message_id
      assert pending_steer.status == :pending
      assert pending_steer.anchor_message_id == next_context.message_id
    end

    test "steer submitted after a terminal handoff is queued in the active child chat" do
      %{user: actor} = user_fixture()
      configuration = steering_configuration!(actor, "http://127.0.0.1:9")

      {source_chat, source_generation, source_step} =
        create_generation!(actor, configuration.id, "Completed handoff source")

      {child_chat, child_generation, _child_step} =
        create_generation!(actor, configuration.id, "Active handoff child",
          parent_chat_id: source_chat.id,
          parent_message_id: source_generation.id,
          parent_relation_kind: :handoff,
          subagent: true
        )

      set_step_status!(source_step, :done, actor)
      set_generation_status!(source_generation, :done, actor)
      create_handoff_result!(actor, source_generation, child_chat, child_generation)

      assert {:ok, queued_message} =
               QueuedMessages.enqueue_steer(
                 source_generation.id,
                 %{content: "Continue in the handoff child"},
                 actor
               )

      assert queued_message.chat_id == child_chat.id
      assert queued_message.kind == :follow_up
      assert queued_message.status == :pending
      assert queued_message.anchor_message_id == child_generation.id
      assert queued_message.target_generation_message_id == nil

      assert {:ok, []} = QueuedMessages.list_for_chat(source_chat.id, actor)
      assert {:ok, [listed]} = QueuedMessages.list_for_chat(child_chat.id, actor)
      assert listed.id == queued_message.id
      assert :active = QueueCoordinator.prepare_next(child_chat.id)
    end

    test "steer submitted after a committed manual handoff is queued in its child chat" do
      %{user: actor} = user_fixture()
      configuration = steering_configuration!(actor, "http://127.0.0.1:9")

      {source_chat, source_generation, source_step} =
        create_generation!(actor, configuration.id, "Completed manual handoff source")

      {child_chat, child_generation, _child_step} =
        create_generation!(actor, configuration.id, "Manual handoff child",
          parent_chat_id: source_chat.id,
          parent_message_id: source_generation.id,
          parent_relation_kind: :handoff,
          subagent: true
        )

      set_step_status!(source_step, :done, actor)
      set_generation_status!(source_generation, :done, actor)

      assert {:ok, queued_message} =
               QueuedMessages.enqueue_steer(
                 source_generation.id,
                 %{content: "Continue after manual handoff"},
                 actor
               )

      assert queued_message.chat_id == child_chat.id
      assert queued_message.kind == :follow_up
      assert queued_message.status == :pending
      assert queued_message.anchor_message_id == child_generation.id
      assert {:ok, []} = QueuedMessages.list_for_chat(source_chat.id, actor)
    end

    test "late steer after canceled uncommitted handoff stays blocked in the source chat" do
      %{user: actor} = user_fixture()
      configuration = steering_configuration!(actor, "http://127.0.0.1:9")

      {source_chat, source_generation, source_step} =
        create_generation!(actor, configuration.id, "Canceled handoff source")

      child_chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{
            note: "",
            llm_configuration_id: configuration.id,
            parent_chat_id: source_chat.id,
            parent_message_id: source_generation.id,
            parent_relation_kind: :handoff,
            subagent: true
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, _child_root} =
        Threads.add_message_to_end(child_chat, :user, "Uncommitted handoff", actor: actor)

      set_step_status!(source_step, :canceled, actor)
      set_generation_status!(source_generation, :canceled, actor)

      assert {:ok, queued_message} =
               QueuedMessages.enqueue_steer(
                 source_generation.id,
                 %{content: "Must remain paused after cancel"},
                 actor
               )

      assert queued_message.chat_id == source_chat.id
      assert queued_message.kind == :follow_up
      assert queued_message.status == :blocked
      assert queued_message.blocked_reason == "generation_canceled"
      assert queued_message.anchor_message_id == source_generation.id

      assert {:ok, []} = QueuedMessages.list_for_chat(child_chat.id, actor)
      assert {:blocked, "generation_canceled"} = QueueCoordinator.prepare_next(source_chat.id)
    end
  end

  # Holds QueueCoordinator.prepare_next/1 of `chat_id` after its unlocked
  # context preparation, before the prepared turn is published.
  defp pause_preparation(chat_id) do
    handler =
      Barrier.attach([:intellectual_club, :generation, :context, :prepared], fn _, _, meta ->
        meta[:chat_id] == chat_id and :prepared
      end)

    supervisor = start_supervised!({Task.Supervisor, []})

    task =
      Task.Supervisor.async_nolink(supervisor, fn -> QueueCoordinator.prepare_next(chat_id) end)

    preparation = Barrier.await(:prepared, 15_000)
    Barrier.detach(handler)
    {task, preparation}
  end

  defp steering_configuration!(actor, base_url \\ nil) do
    provider_attrs = %{type: :openrouter_chat_completion}

    provider_attrs =
      if base_url, do: Map.put(provider_attrs, :base_url, base_url), else: provider_attrs

    create_configuration!(actor, %{
      model_name: "queue-model",
      timeout_seconds: 30,
      provider_attrs: provider_attrs
    })
  end

  # A chat with a finished user/assistant exchange the queue anchors to.
  defp create_chat_with_anchor!(actor, configuration_id \\ nil) do
    chat = create_chat!(actor, maybe_configuration(%{}, configuration_id))
    {:ok, root} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)
    {:ok, anchor} = Threads.add_message_to_end(chat, :assistant, "Answer", actor: actor)
    {chat, root, anchor}
  end

  defp create_generating_assistant!(chat, actor, configuration_id \\ nil) do
    chat = Ash.get!(Chat, chat.id, actor: actor)
    attrs = maybe_configuration(%{parent_id: chat.last_message_id}, configuration_id)
    create_generating_message!(actor, chat, attrs)
  end

  # A chat whose generating reply to `prompt` waits for its provider (step 1).
  defp create_generation!(actor, configuration_id, prompt, chat_attrs \\ []) do
    chat =
      create_chat!(actor, Map.put(Map.new(chat_attrs), :llm_configuration_id, configuration_id))

    generation =
      create_generating_message!(actor, chat, %{
        user_text: prompt,
        llm_configuration_id: configuration_id,
        token_count: 0,
        step: %{
          status: :waiting_provider,
          raw_request: %{
            "model" => "queue-model",
            "messages" => [%{"role" => "user", "content" => prompt}],
            "stream" => true
          }
        }
      })

    {chat, generation, first_step!(actor, generation)}
  end

  defp maybe_configuration(attrs, nil), do: attrs
  defp maybe_configuration(attrs, id), do: Map.put(attrs, :llm_configuration_id, id)

  defp set_generation_status!(message_or_id, status, actor) do
    message = Ash.get!(ChatMessage, id_of(message_or_id), actor: actor)

    set_message_status!(actor, message, status, %{
      error_detail: if(status == :error, do: "test error"),
      finished_at: if(status != :generating, do: DateTime.utc_now())
    })
  end

  defp set_step_status!(step, status, actor) do
    step
    |> Ash.Changeset.for_update(
      :update,
      %{
        status: status,
        finished_at: if(status == :waiting_provider, do: nil, else: DateTime.utc_now())
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp assert_queue_state!(id, actor, status, reason) do
    assert {:ok, queued_message} = QueuedMessages.get(id, actor)
    assert queued_message.status == status
    assert queued_message.blocked_reason == reason
  end

  defp terminal_reason(:error), do: "generation_error"
  defp terminal_reason(:canceled), do: "generation_canceled"

  defp successful_sse(text) do
    sse_chunks([
      %{
        "id" => "chatcmpl-retry",
        "object" => "chat.completion",
        "created" => 1,
        "model" => "queue-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => text},
            "finish_reason" => "stop"
          }
        ]
      }
    ])
  end

  defp load_message_trace!(message_id, actor) do
    Ash.get!(ChatMessage, message_id, actor: actor, load: [steps: [items: [:contents]]])
  end

  defp canonical_items(message) do
    message.steps
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(fn step -> Enum.sort_by(step.items, & &1.sequence) end)
  end

  defp canonical_contents(message) do
    message
    |> canonical_items()
    |> Enum.flat_map(fn item -> Enum.sort_by(item.contents, & &1.sequence) end)
  end

  defp canonical_text(message) do
    message
    |> canonical_contents()
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join(& &1.content_text)
  end

  defp canceled_events_for(message_id, actor),
    do: terminal_events_for(message_id, :canceled, actor)

  defp terminal_events_for(message_id, status, actor) do
    WebPushGenerationEvent
    |> Ash.Query.filter(chat_message_id == ^message_id and status == ^status)
    |> Ash.read!(actor: actor)
  end

  defp without_registered_dispatcher(fun) when is_function(fun, 0) do
    dispatcher = Process.whereis(QueueDispatcher)
    if is_pid(dispatcher), do: true = Process.unregister(QueueDispatcher)

    try do
      fun.()
    after
      if is_pid(dispatcher) and Process.alive?(dispatcher) and
           is_nil(Process.whereis(QueueDispatcher)) do
        true = Process.register(dispatcher, QueueDispatcher)
      end
    end
  end

  defp stop_generation_worker!(message_id) do
    assert [{worker, _metadata}] =
             Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id})

    # Killing the Worker can kill a checked-out SQL borrower and its sandbox.
    # Cancellation joins persistence and receives the lease cleanup ACK first.
    monitor = Process.monitor(worker)
    Worker.cancel(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    message = Ash.get!(ChatMessage, message_id, authorize?: false)
    assert message.status == :canceled
    assert message.generation_fence_token == nil
  end
end
