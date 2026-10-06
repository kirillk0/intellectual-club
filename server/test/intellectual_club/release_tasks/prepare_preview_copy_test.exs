defmodule IntellectualClub.ReleaseTasks.PreparePreviewCopyTest do
  @moduledoc """
  Preparing a copied database for a preview instance: nothing copied from the
  main instance may be resumed or replayed when the preview boots.
  """
  use IntellectualClub.DataCase, async: true

  require Ash.Query

  alias IntellectualClub.BackgroundTasks.BackgroundTask

  alias IntellectualClub.Chat.{
    ChatMessage,
    ChatMessageStep,
    QueuedMessage,
    QueuedMessages,
    Threads
  }

  alias IntellectualClub.Generation.{Persistence, QueueCoordinator}
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Notifications.{WebPushGenerationEvent, WebPushSubscription}
  alias IntellectualClub.ReleaseTasks.PreparePreviewCopy

  describe "generations" do
    test "fails copied in-flight generations so startup recovery has nothing to resume" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      generation = create_generating_message!(actor, chat, step: :waiting_provider)
      [step] = steps_of!(generation)

      assert [%{id: generation_id}] = Persistence.list_generating_messages_for_resume!()
      assert generation_id == generation.id

      assert {:ok, %{generations_failed: 1}} = PreparePreviewCopy.run()

      failed = Ash.get!(ChatMessage, generation.id, authorize?: false)
      assert failed.status == :error
      assert failed.error_detail =~ "copied for a preview instance"
      assert is_nil(failed.generation_fence_token)
      assert %DateTime{} = failed.finished_at

      assert Ash.get!(ChatMessageStep, step.id, authorize?: false).status == :error
      assert Persistence.list_generating_messages_for_resume!() == []
    end
  end

  describe "queued messages" do
    test "pauses pending follow-ups and steering so the queue dispatcher starts no turn" do
      %{user: actor} = user_fixture()

      active_chat = create_chat!(actor)
      generation = create_generating_message!(actor, active_chat)
      {:ok, steer} = QueuedMessages.enqueue_steer(generation.id, "Steer", actor)

      {:ok, follow_up} =
        QueuedMessages.enqueue_follow_up(active_chat.id, %{content: "Next"}, actor)

      idle_chat = create_chat!(actor)
      {:ok, _question} = Threads.add_message_to_end(idle_chat, :user, "Question", actor: actor)
      {:ok, _answer} = Threads.add_message_to_end(idle_chat, :assistant, "Answer", actor: actor)

      {:ok, idle_follow_up} =
        QueuedMessages.enqueue_follow_up(idle_chat.id, %{content: "Later"}, actor)

      assert Enum.sort(QueueCoordinator.ready_chat_ids()) ==
               Enum.sort([active_chat.id, idle_chat.id])

      assert {:ok, %{queued_messages_paused: 3}} = PreparePreviewCopy.run()

      assert QueueCoordinator.ready_chat_ids() == []

      converted = queued!(steer)
      assert converted.kind == :follow_up
      assert converted.status == :blocked
      assert converted.blocked_reason == "preview_copy"
      assert converted.anchor_message_id == generation.id
      assert is_nil(converted.target_generation_message_id)

      for queued <- [follow_up, idle_follow_up] do
        paused = queued!(queued)
        assert paused.kind == :follow_up
        assert paused.status == :blocked
        assert paused.blocked_reason == "preview_copy"
      end

      # The pause is not a terminal-generation reason: settling the queue head
      # after a completed turn must not resume it on its own.
      assert {:blocked, "preview_copy"} = QueueCoordinator.prepare_next(idle_chat.id)
      assert queued!(idle_follow_up).status == :blocked
    end
  end

  describe "background tasks" do
    test "fails active tasks without changing finished ones" do
      %{user: actor} = user_fixture()
      queued = create_background_task!(actor)
      running = create_background_task!(actor, status: :running, cancel_requested: true)
      completed = create_background_task!(actor, status: :completed)

      assert {:ok, %{background_tasks_failed: 2}} = PreparePreviewCopy.run()

      for task <- [queued, running] do
        failed = Ash.get!(BackgroundTask, task.id, authorize?: false)
        assert failed.status == :failed
        assert failed.error["code"] == "preview_copy"
        assert failed.error["outcome"] == "unknown"
        assert %DateTime{} = failed.finished_at
      end

      assert Ash.get!(BackgroundTask, completed.id, authorize?: false).status == :completed
    end
  end

  describe "web push" do
    test "deletes subscriptions and acknowledges undelivered generation events" do
      %{user: actor} = user_fixture()
      %{user: other} = user_fixture()
      create_subscription!(actor, "https://push.example/actor")
      create_subscription!(other, "https://push.example/other")

      chat = create_chat!(actor)
      done = create_message!(actor, chat)
      failed = create_message!(actor, chat, status: :error)
      undelivered = create_generation_event!(actor, done, status: :done, delivered_count: -1)

      suppressed =
        create_generation_event!(actor, failed,
          status: :error,
          suppressed: true,
          delivered_count: 0
        )

      assert {:ok, %{web_push_subscriptions_deleted: 2, web_push_events_acknowledged: 1}} =
               PreparePreviewCopy.run()

      assert Ash.read!(WebPushSubscription, authorize?: false) == []

      acknowledged = Ash.get!(WebPushGenerationEvent, undelivered.id, authorize?: false)
      assert acknowledged.delivered_count == 0
      assert acknowledged.suppressed == false

      assert Ash.get!(WebPushGenerationEvent, suppressed.id, authorize?: false).suppressed
    end
  end

  describe "OAuth credentials" do
    test "clears rotating refresh tokens and keeps the providers and their API keys" do
      %{user: actor} = user_fixture()

      oauth_provider =
        create_provider!(actor,
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          api_key: nil,
          oauth_refresh_token: "rt_main_instance"
        )

      api_key_provider = create_provider!(actor, type: :openrouter_chat_completion)

      assert {:ok, %{oauth_refresh_tokens_cleared: 1}} = PreparePreviewCopy.run()

      cleared =
        LlmProvider
        |> Ash.Query.filter(id == ^oauth_provider.id)
        |> Ash.Query.load(:credentials_present)
        |> Ash.read_one!(actor: actor)

      assert cleared.auth_method == "openai_oauth_refresh_token"
      assert is_nil(cleared.oauth_refresh_token)
      assert cleared.credentials_present == []

      assert Ash.get!(LlmProvider, api_key_provider.id, actor: actor).api_key == "test-key"
    end
  end

  test "is idempotent" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    generation = create_generating_message!(actor, chat, step: :waiting_tools)
    {:ok, _follow_up} = QueuedMessages.enqueue_follow_up(chat.id, %{content: "Next"}, actor)
    create_background_task!(actor, generation: generation)
    create_subscription!(actor, "https://push.example/actor")
    done = create_message!(actor, chat)
    create_generation_event!(actor, done, status: :done, delivered_count: -1)

    create_provider!(actor,
      type: :responses,
      auth_method: :openai_oauth_refresh_token,
      base_url: "https://api.openai.com/v1",
      api_key: nil,
      oauth_refresh_token: "rt_main_instance"
    )

    assert {:ok, first} = PreparePreviewCopy.run()
    assert Enum.all?(Map.values(first), &(&1 == 1))

    assert {:ok, second} = PreparePreviewCopy.run()
    assert Enum.all?(Map.values(second), &(&1 == 0))
    assert Ash.get!(ChatMessage, generation.id, authorize?: false).status == :error
  end

  defp steps_of!(message) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^message.id)
    |> Ash.read!(authorize?: false)
  end

  defp queued!(queued_message) do
    Ash.get!(QueuedMessage, queued_message.id, authorize?: false)
  end

  defp create_subscription!(actor, endpoint) do
    create!(
      WebPushSubscription,
      %{
        endpoint: endpoint,
        p256dh: "p256dh-key",
        auth: "auth-key",
        key_revision: 1,
        last_seen_at: DateTime.utc_now()
      },
      actor
    )
  end

  defp create_generation_event!(actor, message, attrs) do
    create!(WebPushGenerationEvent, Map.put(Map.new(attrs), :chat_message_id, message.id), actor)
  end
end
