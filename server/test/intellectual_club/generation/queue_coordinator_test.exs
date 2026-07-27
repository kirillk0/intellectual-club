defmodule IntellectualClub.Generation.QueueCoordinatorTest do
  use IntellectualClub.DataCase, async: false

  require Ash.Query

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Generation.QueueDispatcher
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Notifications.WebPushGenerationEvent

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

  test "error and cancel block the backlog while a later Done reopens it" do
    %{user: actor} = user_fixture()

    Enum.each(
      [
        {:error, "generation_error"},
        {:canceled, "generation_canceled"}
      ],
      fn {terminal_status, expected_reason} ->
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
    )
  end

  test "cancel_generation atomically cancels the assistant, blocks its queue, and records an event" do
    %{user: actor} = user_fixture()
    {chat, _root, _anchor} = create_chat_with_anchor!(actor)
    generation = create_generating_assistant!(chat, actor)

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

    assert [%WebPushGenerationEvent{suppressed: false, delivered_count: -1}] =
             canceled_events_for(generation.id, actor)
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

  test "a pending steer that loses the terminal race becomes a follow-up" do
    %{user: actor} = user_fixture()
    configuration = create_steering_configuration!(actor)
    {chat, _root, _anchor} = create_chat_with_anchor!(actor, configuration.id)
    generation = create_generating_assistant!(chat, actor, configuration.id)

    assert {:ok, queued_steer} =
             QueuedMessages.enqueue_steer(generation.id, %{content: "Late steer"}, actor)

    assert queued_steer.kind == :steer
    assert queued_steer.target_generation_message_id == generation.id

    set_generation_status!(generation, :done, actor)

    assert {:ok, %{converted_steers: 1, status: :done}} =
             QueueCoordinator.settle_generation(generation.id, :done)

    assert {:ok, converted} = QueuedMessages.get(queued_steer.id, actor)
    assert converted.kind == :follow_up
    assert converted.status == :pending
    assert converted.anchor_message_id == generation.id
    assert converted.target_generation_message_id == nil
    assert converted.blocked_reason == nil

    assert {:ok, _context} = QueueCoordinator.prepare_next(chat.id)
    assert {:ok, delivered} = QueuedMessages.get(queued_steer.id, actor)
    assert canonical_text(load_message_trace!(delivered.user_message_id, actor)) == "Late steer"
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

  test "Done fallback starts the prepared worker when the dispatcher is unavailable" do
    %{user: actor} = user_fixture()
    {chat, _root, _anchor} = create_chat_with_anchor!(actor)
    generation = create_generating_assistant!(chat, actor)

    assert {:ok, _queued} =
             QueuedMessages.enqueue_follow_up(chat.id, %{content: "Fallback follow-up"}, actor)

    set_generation_status!(generation, :done, actor)

    with_demo_delay(1_000, fn ->
      assert {:advanced, next_message_id} =
               without_registered_dispatcher(fn ->
                 QueueDispatcher.generation_finished(generation.id, :done)
               end)

      assert {:ok, _poll} = GenerationSupervisor.poll_generation(next_message_id)
      stop_generation_worker!(next_message_id)
    end)
  end

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

    with_demo_delay(1_000, fn ->
      assert {:transferred, %{transferred_count: 1, dispatch: {:advanced, child_generation_id}}} =
               without_registered_dispatcher(fn ->
                 QueueDispatcher.handoff(source_message.id, child_chat.id, nil)
               end)

      assert {:ok, delivered} = QueuedMessages.get(queued.id, actor)
      assert delivered.chat_id == child_chat.id
      assert delivered.status == :delivered
      assert delivered.assistant_message_id == child_generation_id
      assert {:ok, _poll} = GenerationSupervisor.poll_generation(child_generation_id)
      stop_generation_worker!(child_generation_id)
    end)
  end

  defp create_chat_with_anchor!(actor, llm_configuration_id \\ nil) do
    attrs =
      %{note: ""}
      |> maybe_put(:llm_configuration_id, llm_configuration_id)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)
    {:ok, anchor} = Threads.add_message_to_end(chat, :assistant, "Answer", actor: actor)
    {chat, root, anchor}
  end

  defp create_generating_assistant!(chat, actor, llm_configuration_id \\ nil) do
    chat = Ash.get!(Chat, chat.id, actor: actor)

    attrs =
      %{
        chat_id: chat.id,
        parent_id: chat.last_message_id
      }
      |> maybe_put(:llm_configuration_id, llm_configuration_id)

    ChatMessage
    |> Ash.Changeset.for_create(:create_generating_assistant, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp set_generation_status!(message_or_id, status, actor) do
    id = if is_integer(message_or_id), do: message_or_id, else: message_or_id.id
    message = Ash.get!(ChatMessage, id, actor: actor)

    finished_at = if status == :generating, do: nil, else: DateTime.utc_now()

    message
    |> Ash.Changeset.for_update(
      :set_generation_state,
      %{status: status, finished_at: finished_at},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp load_message_trace!(message_id, actor) do
    Ash.get!(ChatMessage, message_id,
      actor: actor,
      load: [steps: [items: [:contents]]]
    )
  end

  defp canonical_contents(message) do
    message.steps
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(fn step -> Enum.sort_by(step.items, & &1.sequence) end)
    |> Enum.flat_map(fn item -> Enum.sort_by(item.contents, & &1.sequence) end)
  end

  defp canonical_text(message) do
    message
    |> canonical_contents()
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join(& &1.content_text)
  end

  defp create_steering_configuration!(actor) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Queue coordinator steering provider",
          type: :openrouter_chat_completion,
          auth_method: :api_key,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "queue-coordinator-model",
        note: "",
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        supports_steering: true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp canceled_events_for(message_id, actor) do
    WebPushGenerationEvent
    |> Ash.Query.filter(chat_message_id == ^message_id and status == :canceled)
    |> Ash.read!(actor: actor)
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp without_registered_dispatcher(fun) when is_function(fun, 0) do
    dispatcher = Process.whereis(QueueDispatcher)

    if is_pid(dispatcher) do
      true = Process.unregister(QueueDispatcher)
    end

    try do
      fun.()
    after
      if is_pid(dispatcher) and Process.alive?(dispatcher) and
           is_nil(Process.whereis(QueueDispatcher)) do
        true = Process.register(dispatcher, QueueDispatcher)
      end
    end
  end

  defp with_demo_delay(delay_ms, fun) when is_integer(delay_ms) and is_function(fun, 0) do
    previous = Application.get_env(:intellectual_club, :demo_chunk_delay_ms)
    Application.put_env(:intellectual_club, :demo_chunk_delay_ms, delay_ms)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:intellectual_club, :demo_chunk_delay_ms)
      else
        Application.put_env(:intellectual_club, :demo_chunk_delay_ms, previous)
      end
    end
  end

  defp stop_generation_worker!(message_id) do
    assert [{worker, _metadata}] =
             Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id})

    assert :ok = DynamicSupervisor.terminate_child(GenerationSupervisor, worker)
  end
end
