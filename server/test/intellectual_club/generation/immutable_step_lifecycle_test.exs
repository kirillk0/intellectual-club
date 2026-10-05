defmodule IntellectualClub.Generation.ImmutableStepLifecycleTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Test.GenerationRuntime, only: [with_generation_lease: 2]

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Llm.Providers.Common.PreparedRequest
  alias IntellectualClub.Llm.Providers.Responses.Provider, as: Responses

  require Ash.Query

  describe "request steps" do
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
        Ash.get!(ChatMessageStep, step.id,
          actor: actor,
          load: [:raw_response, items: [:contents]]
        )

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

    test "the removed request setter cannot mutate a runtime step" do
      runtime = RuntimeTrace.new_step(id: 1, raw_request: %{"saved" => true})

      assert RuntimeTrace.apply_event(runtime, {:set_step_raw_request, %{"changed" => true}}) ==
               runtime
    end
  end

  describe "steering transitions" do
    test "queued steering creates a receiving step without operational trace items" do
      %{user: actor} = user_fixture()
      message = message!(actor)
      request = %{"model" => "test", "messages" => []}
      step_id = Persistence.ensure_step_started!(message.id, request)
      create_text_item!(actor, step_id, "Interrupted partial")
      assert {:ok, queued} = QueuedMessages.enqueue_steer(message.id, "Redirect", actor)

      next_request = %{
        "model" => "test",
        "messages" => [%{"role" => "user", "content" => "Redirect"}]
      }

      with_generation_lease(message.id, fn lease ->
        specs = [%{id: queued.id, text: "Redirect", updated_at: queued.updated_at}]

        next =
          Persistence.persist_queued_steering_before_provider!(
            message.id,
            step_id,
            specs,
            next_request,
            lease: lease
          )

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
        refute Enum.any?(old.items, &(&1.type == :other))
        assert Enum.count(next.step.items, &(&1.type == :steering)) == 1

        assert {:applied, reconciled} =
                 Persistence.reconcile_step_transition!(
                   message.id,
                   step_id,
                   :before_response,
                   lease: lease
                 )

        assert reconciled.step_id == next.step_id
        assert reconciled.item_id == next.item_id

        assert_raise ArgumentError, ~r/successor already exists/, fn ->
          Persistence.persist_queued_steering_before_provider!(
            message.id,
            step_id,
            specs,
            next_request,
            lease: lease
          )
        end
      end)

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

      with_generation_lease(message.id, fn lease ->
        assert {:error, :queued_steering_changed} =
                 Persistence.persist_queued_steering_before_provider!(
                   message.id,
                   step_id,
                   [%{id: queued.id, text: "Stale text"}],
                   next_request,
                   lease: lease
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

        specs = [%{id: queued.id, text: "Queued redirect", updated_at: queued.updated_at}]

        next =
          Persistence.persist_queued_steering_before_provider!(
            message.id,
            step_id,
            specs,
            next_request,
            lease: lease
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

        assert {:applied, reconciled} =
                 Persistence.reconcile_step_transition!(
                   message.id,
                   step_id,
                   :before_response,
                   lease: lease
                 )

        assert reconciled.step_id == next.step_id
        assert reconciled.deliveries == next.deliveries
      end)
    end

    test "repeating a generation transition cannot overwrite a progressed successor" do
      %{user: actor} = user_fixture()
      message = message!(actor)

      request = %{
        "model" => "test",
        "messages" => [%{"role" => "user", "content" => String.duplicate("history", 400)}]
      }

      step_id = Persistence.ensure_step_started!(message.id, request)

      with_generation_lease(message.id, fn lease ->
        next =
          Persistence.persist_retry_error_and_start_next_step!(
            message.id,
            step_id,
            request,
            "Temporary",
            attempt: 1,
            lease: lease
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

        assert_raise ArgumentError, ~r/successor already exists/, fn ->
          Persistence.persist_retry_error_and_start_next_step!(
            message.id,
            step_id,
            request,
            "Temporary",
            attempt: 1,
            lease: lease
          )
        end

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
      end)
    end
  end

  describe "archive and lease boundaries" do
    test "archive CRUD permits arbitrary step sequences" do
      %{user: actor} = user_fixture()
      message = message!(actor)

      archived =
        message
        |> Ash.Changeset.for_update(
          :set_generation_state,
          %{status: :done, token_count: 0, finished_at: DateTime.utc_now()},
          actor: actor
        )
        |> Ash.update!(actor: actor)

      first_id = Persistence.ensure_step_started!(archived.id, 3, %{"archive" => 1}, [])
      second_id = Persistence.ensure_step_started!(archived.id, 9, %{"archive" => 2}, [])

      first = Ash.get!(ChatMessageStep, first_id, actor: actor)

      first
      |> Ash.Changeset.for_update(:update, %{status: :error}, actor: actor)
      |> Ash.update!(actor: actor)

      Ash.get!(ChatMessageStep, second_id, actor: actor) |> Ash.destroy!(actor: actor)

      assert Ash.get!(ChatMessageStep, first_id, actor: actor).status == :error
      assert {:error, _reason} = Ash.get(ChatMessageStep, second_id, actor: actor)
    end

    test "prepared archive write cannot cross into a live generation without a lease" do
      %{user: actor} = user_fixture()
      message = message!(actor)

      archived =
        message
        |> Ash.Changeset.for_update(
          :set_generation_state,
          %{status: :done, token_count: 0, finished_at: DateTime.utc_now()},
          actor: actor
        )
        |> Ash.update!(actor: actor)

      first = Persistence.create_request_step!(archived, 1, %{"archive" => 1})

      {changeset, _snapshot} =
        StepRequests.prepare_create!(
          %{chat_message_id: archived.id, sequence: 2, status: :waiting_provider},
          %{"archive" => 2},
          actor: actor,
          previous_step: first.step,
          previous_request: first.request
        )

      archived
      |> Ash.Changeset.for_update(
        :set_generation_state,
        %{status: :generating, token_count: 0, finished_at: nil},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      assert {:error, error} =
               Ash.transaction([ChatMessageStep], fn ->
                 Ash.create!(changeset, actor: actor)
               end)

      assert Exception.message(error) =~ "generation_lease_required"

      assert [first.step.id] ==
               ChatMessageStep
               |> Ash.Query.filter(chat_message_id == ^archived.id)
               |> Ash.Query.sort(sequence: :asc)
               |> Ash.read!(actor: actor)
               |> Enum.map(& &1.id)
    end

    test "a live generation successor cannot be created without a fenced lease" do
      %{user: actor} = user_fixture()
      message = message!(actor)
      request = %{"model" => "test"}
      first_id = Persistence.ensure_step_started!(message.id, request)

      assert_raise ArgumentError, ~r/requires a fenced lease/, fn ->
        Persistence.persist_retry_error_and_start_next_step!(
          message.id,
          first_id,
          request,
          "Temporary"
        )
      end

      assert_raise ArgumentError, ~r/requires a fenced lease/, fn ->
        Persistence.ensure_step_started!(message.id, 2, request, [])
      end
    end
  end

  defp message!(actor) do
    create_generating_message!(actor, create_chat!(actor), %{
      user_text: "Immutable request",
      token_count: 0
    })
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
end
