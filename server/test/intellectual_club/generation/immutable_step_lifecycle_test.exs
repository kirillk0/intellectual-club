defmodule IntellectualClub.Generation.ImmutableStepLifecycleTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Llm.Providers.Common.PreparedRequest
  alias IntellectualClub.Llm.Providers.Responses.Provider, as: Responses

  require Ash.Query

  test "creation publishes the final provider request and refuses to reset an existing step" do
    %{user: actor} = user_fixture()
    message = message!(actor)
    context = %{owner_id: actor.id, chat_id: message.chat_id, adapter_module: Responses}
    raw = %{"model" => "test", "input" => [], "prompt_cache_key" => "caller-value"}
    expected = PreparedRequest.prepare(Responses, raw, context)

    %{step: step, request: request} =
      Persistence.create_request_step!(message, 1, raw, request_context: context)

    assert request == expected
    assert StepRequests.request_for_step!(step.id, actor: actor) == request

    runtime = answer_runtime(step.id, 1, request, "Already finished")
    Persistence.persist_provider_completed!(message.id, runtime)

    assert_raise ArgumentError, ~r/Step already exists/, fn ->
      Persistence.ensure_step_started!(message.id, request)
    end

    saved =
      Ash.get!(ChatMessageStep, step.id, actor: actor, load: [:raw_response, items: [:contents]])

    assert saved.status == :done
    assert saved.raw_response == %{"id" => "completed"}
    assert answer_text(saved) == "Already finished"
  end

  test "a request-only provider restart has a nil response and remains cancelable" do
    %{user: actor} = user_fixture()
    message = message!(actor)
    request = %{"model" => "test", "messages" => []}
    %{step: step} = Persistence.create_request_step!(message, 1, request)
    %{runtime_step: runtime} = Persistence.load_step_for_provider_restart!(step.id)
    assert runtime.raw_response == nil
    Persistence.persist_canceled!(message.id, runtime)
    assert Ash.get!(ChatMessage, message.id, actor: actor).status == :canceled
    saved = Ash.get!(ChatMessageStep, step.id, actor: actor, load: [:raw_response])
    assert saved.raw_response == nil
    assert saved.status == :canceled
  end

  test "snapshots require the saved ID, message, sequence and immutable request" do
    %{user: actor} = user_fixture()
    message = message!(actor)
    other_message = message!(actor)
    request = %{"model" => "test", "messages" => []}
    step_id = Persistence.ensure_step_started!(message.id, request)
    runtime = answer_runtime(step_id, 1, request, "Output")

    assert_raise ArgumentError, ~r/Runtime request differs/, fn ->
      Persistence.persist_provider_completed!(message.id, %{
        runtime
        | raw_request: %{"changed" => true}
      })
    end

    assert_raise ArgumentError, ~r/sequence does not match/, fn ->
      Persistence.persist_provider_completed!(message.id, %{runtime | sequence: 2})
    end

    assert_raise ArgumentError, ~r/does not belong/, fn ->
      Persistence.persist_provider_completed!(other_message.id, runtime)
    end

    assert_raise ArgumentError, ~r/requires its saved step ID/, fn ->
      Persistence.persist_provider_completed!(message.id, %{runtime | id: nil})
    end

    assert StepRequests.request_for_step!(step_id, actor: actor) == request
    assert Ash.get!(ChatMessageStep, step_id, actor: actor).status == :waiting_provider

    Ash.get!(ChatMessageStep, step_id, actor: actor) |> Ash.destroy!(actor: actor)

    assert_raise Ash.Error.Invalid, fn ->
      Persistence.persist_provider_completed!(message.id, runtime)
    end

    assert [] ==
             ChatMessageStep
             |> Ash.Query.filter(chat_message_id == ^message.id)
             |> Ash.read!(actor: actor)
  end

  test "steering creates a receiving step, removes interrupted answers, and preserves prior raw" do
    %{user: actor} = user_fixture()
    message = message!(actor)
    request = %{"model" => "test", "messages" => []}
    step_id = Persistence.ensure_step_started!(message.id, request)
    add_partial_answer!(step_id, actor)

    next_request = %{
      "model" => "test",
      "messages" => [%{"role" => "user", "content" => "Redirect"}]
    }

    next =
      Persistence.persist_steering_before_provider!(message.id, step_id, "Redirect", next_request)

    refute next.step_id == step_id
    assert next.step_sequence == 2
    assert next.runtime_step.raw_request == next_request
    assert StepRequests.request_for_step!(step_id, actor: actor) == request
    assert StepRequests.request_for_step!(next.step_id, actor: actor) == next_request
    assert Ash.get!(ChatMessage, message.id, actor: actor).status == :generating

    old = Ash.get!(ChatMessageStep, step_id, actor: actor, load: [items: [:contents]])
    assert old.status == :canceled
    assert %DateTime{} = old.finished_at
    refute Enum.any?(old.items, &(&1.type == :answer))
    assert Enum.any?(old.items, &(&1.type == :error))
    assert Enum.count(next.step.items, &(&1.type == :steering)) == 1

    again =
      Persistence.persist_steering_before_provider!(message.id, step_id, "Redirect", next_request)

    assert again.step_id == next.step_id
    assert again.item_id == next.item_id

    assert_raise ArgumentError, ~r/Conflicting generation step transition/, fn ->
      Persistence.persist_steering_before_provider!(
        message.id,
        step_id,
        "Different",
        next_request
      )
    end

    assert_raise ArgumentError, ~r/stale step/, fn ->
      Persistence.persist_provider_completed!(
        message.id,
        answer_runtime(step_id, 1, request, "Stale")
      )
    end
  end

  test "queued steering delivery and the new receiving step are one atomic transition" do
    %{user: actor} = user_fixture()
    message = message!(actor)
    request = %{"model" => "test", "messages" => []}
    step_id = Persistence.ensure_step_started!(message.id, request)
    assert {:ok, queued} = QueuedMessages.enqueue_steer(message.id, "Queued redirect", actor)

    next_request =
      Map.put(request, "messages", [%{"role" => "user", "content" => "Queued redirect"}])

    assert {:error, :queued_steering_changed} =
             Persistence.persist_queued_steering_before_provider!(
               message.id,
               step_id,
               [%{id: queued.id, text: "Stale text"}],
               next_request
             )

    assert Ash.get!(ChatMessageStep, step_id, actor: actor).status == :waiting_provider

    assert [only_step] =
             ChatMessageStep
             |> Ash.Query.filter(chat_message_id == ^message.id)
             |> Ash.read!(actor: actor)

    assert only_step.id == step_id
    assert {:ok, still_pending} = QueuedMessages.get(queued.id, actor)
    assert still_pending.status == :pending
    assert still_pending.steering_item_id == nil

    specs = [%{id: queued.id, text: "Queued redirect"}]

    next =
      Persistence.persist_queued_steering_before_provider!(
        message.id,
        step_id,
        specs,
        next_request
      )

    assert next.step_id != step_id
    assert next.deliveries == [%{queued_message_id: queued.id, item_id: next.item_id}]
    assert {:ok, delivered} = QueuedMessages.get(queued.id, actor)
    assert delivered.status == :delivered
    assert delivered.steering_item_id == next.item_id
    assert delivered.contents == []
    item = Ash.get!(ChatMessageItem, next.item_id, actor: actor)
    assert item.chat_message_step_id == next.step_id
    assert StepRequests.request_for_step!(step_id, actor: actor) == request
    assert StepRequests.request_for_step!(next.step_id, actor: actor) == next_request

    again =
      Persistence.persist_queued_steering_before_provider!(
        message.id,
        step_id,
        specs,
        next_request
      )

    assert again.step_id == next.step_id
    assert again.deliveries == next.deliveries
  end

  test "repeating a proven retry transition cannot overwrite a progressed successor" do
    %{user: actor} = user_fixture()
    message = message!(actor)

    request = %{
      "model" => "test",
      "messages" => [%{"role" => "user", "content" => String.duplicate("history", 400)}]
    }

    step_id = Persistence.ensure_step_started!(message.id, request)

    next =
      Persistence.persist_retry_error_and_start_next_step!(
        message.id,
        step_id,
        request,
        "Temporary",
        attempt: 1
      )

    runtime = answer_runtime(next.step_id, 2, request, "Durable successor")
    Persistence.persist_provider_completed!(message.id, runtime)

    saved =
      Ash.get!(ChatMessageStep, next.step_id,
        actor: actor,
        load: [:raw_response, items: [:contents]]
      )

    assert saved.request_mode == :patch
    assert StepRequests.request_for_step!(saved.id, actor: actor) == request

    again =
      Persistence.persist_retry_error_and_start_next_step!(
        message.id,
        step_id,
        request,
        "Temporary",
        attempt: 1
      )

    assert again.step_id == next.step_id

    preserved =
      Ash.get!(ChatMessageStep, next.step_id,
        actor: actor,
        load: [:raw_response, items: [:contents]]
      )

    assert preserved.status == :done
    assert preserved.finished_at == saved.finished_at
    assert preserved.raw_response == saved.raw_response
    assert Enum.map(preserved.items, & &1.id) == Enum.map(saved.items, & &1.id)
    assert answer_text(preserved) == "Durable successor"

    assert_raise ArgumentError, ~r/Conflicting generation step transition/, fn ->
      Persistence.persist_retry_error_and_start_next_step!(
        message.id,
        step_id,
        Map.put(request, "changed", true),
        "Temporary"
      )
    end
  end

  test "matching request alone does not prove an existing successor belongs to a retry" do
    %{user: actor} = user_fixture()
    message = message!(actor)
    request = %{"model" => "test"}
    first_id = Persistence.ensure_step_started!(message.id, request)
    second_id = Persistence.ensure_step_started!(message.id, 2, request, [])

    assert_raise ArgumentError, ~r/Conflicting generation step transition/, fn ->
      Persistence.persist_retry_error_and_start_next_step!(
        message.id,
        first_id,
        request,
        "Temporary"
      )
    end

    assert Ash.get!(ChatMessageStep, first_id, actor: actor).status == :waiting_provider
    assert Ash.get!(ChatMessageStep, second_id, actor: actor).status == :waiting_provider
  end

  test "the removed request setter cannot mutate a runtime step" do
    runtime = RuntimeTrace.new_step(id: 1, raw_request: %{"saved" => true})

    assert RuntimeTrace.apply_event(runtime, {:set_step_raw_request, %{"changed" => true}}) ==
             runtime
  end

  defp message!(actor) do
    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, parent} = Threads.add_message_to_end(chat, :user, "Immutable request", actor: actor)

    ChatMessage
    |> Ash.Changeset.for_create(
      :create_generating_assistant,
      %{chat_id: chat.id, parent_id: parent.id, token_count: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp answer_runtime(step_id, sequence, request, text) do
    RuntimeTrace.new_step(id: step_id, sequence: sequence, raw_request: request)
    |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, text})
    |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "completed"}})
    |> RuntimeTrace.apply_event({:set_step_response_final, true})
  end

  defp answer_text(step) do
    step.items
    |> Enum.filter(&(&1.type == :answer))
    |> Enum.flat_map(& &1.contents)
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join("", & &1.content_text)
  end

  defp add_partial_answer!(step_id, actor) do
    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step_id, type: :answer, sequence: 1},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :text,
        content_text: "Interrupted partial"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
