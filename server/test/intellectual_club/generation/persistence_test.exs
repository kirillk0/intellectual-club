defmodule IntellectualClub.Generation.PersistenceTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Test.GenerationRuntime, only: [with_generation_lease: 2]

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.LinkedForkCleanup
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Llm.LlmUsageRecord

  require Ash.Query

  describe "provider completion" do
    test "persisted intermediate steps get finished_at while the next step remains open" do
      %{user: actor} = user_fixture()

      chat =
        create_chat!(actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      assistant_message =
        create!(
          ChatMessage,
          :create_generating_assistant,
          %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
          actor
        )

      assert assistant_message.finished_at == nil

      step_1_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          },
          []
        )

      step_1 =
        RuntimeTrace.new_step(
          id: step_1_id,
          sequence: 1,
          raw_request: StepRequests.request_for_step!(step_1_id, actor: actor)
        )
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Step one"})

      :ok = Persistence.persist_step_trace_only!(assistant_message.id, step_1)

      step_2_id =
        with_generation_lease(assistant_message.id, fn lease ->
          Persistence.ensure_step_started!(
            assistant_message.id,
            2,
            %{
              "model" => "demo-model",
              "messages" => [%{"role" => "assistant", "content" => "Step one"}]
            },
            lease: lease
          )
        end)

      step_2 =
        RuntimeTrace.new_step(
          id: step_2_id,
          sequence: 2,
          raw_request: StepRequests.request_for_step!(step_2_id, actor: actor)
        )
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Final answer"})

      interim_message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:finished_at]]
        )

      assert interim_message.finished_at == nil

      [persisted_step_1, open_step_2] = Enum.sort_by(interim_message.steps || [], & &1.sequence)
      assert persisted_step_1.sequence == 1
      assert %DateTime{} = persisted_step_1.finished_at
      assert open_step_2.sequence == 2
      assert open_step_2.finished_at == nil

      Persistence.persist_completed!(assistant_message.id, step_2)

      final_message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:finished_at]]
        )

      assert final_message.status == :done
      assert %DateTime{} = final_message.finished_at

      finished_steps = Enum.sort_by(final_message.steps || [], & &1.sequence)
      assert Enum.map(finished_steps, & &1.sequence) == [1, 2]
      assert Enum.all?(finished_steps, &match?(%DateTime{}, &1.finished_at))
    end

    test "persist_completed! stores provider token boundaries for the step" do
      %{user: actor} = user_fixture()

      chat =
        create_chat!(actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      assistant_message =
        create!(
          ChatMessage,
          :create_generating_assistant,
          %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
          actor
        )

      started_at = ~U[2026-04-16 10:00:00.000000Z]
      first_token_at = ~U[2026-04-16 10:00:00.250000Z]
      last_token_at = ~U[2026-04-16 10:00:02.250000Z]

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          },
          started_at: started_at
        )

      runtime_step =
        RuntimeTrace.new_step(
          id: step_id,
          sequence: 1,
          started_at: started_at,
          raw_request: StepRequests.request_for_step!(step_id, actor: actor),
          output_tokens: 12
        )
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Final answer"})

      runtime_step = %{
        runtime_step
        | first_token_at: first_token_at,
          last_token_at: last_token_at
      }

      :ok = Persistence.persist_completed!(assistant_message.id, runtime_step)

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:first_token_at, :last_token_at, :finished_at]]
        )

      [step] = Enum.sort_by(message.steps || [], & &1.sequence)
      assert step.first_token_at == first_token_at
      assert step.last_token_at == last_token_at
      assert %DateTime{} = step.finished_at
    end

    test "persist_completed! keeps mixed answer types and counts handoff summary text" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model"},
          []
        )

      runtime_step =
        RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: %{"model" => "demo-model"})
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
        |> RuntimeTrace.apply_event({:ensure_item, "handoff-summary", :handoff_summary, 2})
        |> RuntimeTrace.apply_event(
          {:set_text, "handoff-summary", :handoff_summary, 1, "Transfer summary text"}
        )
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Ordinary answer"})

      assert %DateTime{} = runtime_step.first_token_at
      :ok = Persistence.persist_completed!(assistant_message.id, runtime_step)

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:raw_request, :raw_response, items: [:contents]]]
        )

      assert message.token_count > 0
      assert [step] = message.steps

      assert Enum.map(Enum.sort_by(step.items, & &1.sequence), & &1.type) == [
               :answer,
               :handoff_summary
             ]
    end

    test "persist_completed! records durable usage for assistant steps" do
      %{user: actor} = user_fixture()
      provider = create_provider!(actor, name: "Usage provider")
      configuration = create_configuration!(actor, provider: provider, model_name: "usage-model")

      chat =
        create!(
          Chat,
          :create,
          %{
            llm_configuration_id: configuration.id,
            note: ""
          },
          actor
        )

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      assistant_message =
        create!(
          ChatMessage,
          :create_generating_assistant,
          %{
            chat_id: chat.id,
            parent_id: user_message.id,
            llm_configuration_id: configuration.id,
            token_count: 0
          },
          actor
        )

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "usage-model"},
          []
        )

      runtime_step =
        RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: %{"model" => "usage-model"})
        |> RuntimeTrace.apply_event(
          {:set_step_usage,
           %{
             input_tokens: 11,
             output_tokens: 7,
             cost: 0.015,
             responses: %{"total_tokens" => 18}
           }}
        )
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Final answer"})

      :ok = Persistence.persist_completed!(assistant_message.id, runtime_step)

      [usage] =
        LlmUsageRecord
        |> Ash.Query.filter(chat_message_step_id_snapshot == ^step_id)
        |> Ash.read!(actor: actor)

      assert usage.usage_user_id_snapshot == actor.id
      assert usage.configuration_owner_id_snapshot == actor.id
      assert usage.llm_configuration_id_snapshot == configuration.id
      assert usage.chat_message_id_snapshot == assistant_message.id
      assert usage.step_sequence == 1
      assert usage.input_tokens == 11
      assert usage.output_tokens == 7
      assert usage.cost == 0.015
      assert usage.raw_usage["responses"] == %{"total_tokens" => 18}

      changed_runtime_step =
        RuntimeTrace.apply_event(
          runtime_step,
          {:set_step_usage, %{input_tokens: 999, output_tokens: 999, cost: 999.0}}
        )

      :ok = Persistence.persist_completed!(assistant_message.id, changed_runtime_step)
      fields = Enum.map(Ash.Resource.Info.attributes(LlmUsageRecord), & &1.name)
      persisted_usage = Ash.get!(LlmUsageRecord, usage.id, actor: actor)
      assert Map.take(persisted_usage, fields) == Map.take(usage, fields)
    end

    test "status-only transitions preserve immutable provider usage without accounting copied steps" do
      %{user: actor} = user_fixture()
      provider = create_provider!(actor, name: "Usage lifecycle provider")

      configuration =
        create_configuration!(actor, provider: provider, model_name: "usage-lifecycle-model")

      chat =
        create!(Chat, :create, %{llm_configuration_id: configuration.id, note: ""}, actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      assistant_message =
        create!(
          ChatMessage,
          :create_generating_assistant,
          %{
            chat_id: chat.id,
            parent_id: user_message.id,
            llm_configuration_id: configuration.id,
            token_count: 0
          },
          actor
        )

      copied_step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "usage-lifecycle-model"},
          []
        )

      ChatMessageStep
      |> Ash.get!(copied_step_id, actor: actor)
      |> Ash.Changeset.for_update(
        :update,
        %{input_tokens: 10, output_tokens: 5, cost: 0.02, status: :waiting_tools},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      :ok = Persistence.mark_step_done!(copied_step_id)

      assert [] ==
               LlmUsageRecord
               |> Ash.Query.filter(chat_message_step_id_snapshot == ^copied_step_id)
               |> Ash.read!(actor: actor)

      provider_step_id =
        with_generation_lease(assistant_message.id, fn lease ->
          Persistence.ensure_step_started!(
            assistant_message.id,
            2,
            %{"model" => "usage-lifecycle-model"},
            lease: lease
          )
        end)

      runtime_step =
        RuntimeTrace.new_step(
          id: provider_step_id,
          sequence: 2,
          raw_request: %{"model" => "usage-lifecycle-model"}
        )
        |> RuntimeTrace.apply_event(
          {:set_step_usage, %{input_tokens: 12, output_tokens: 6, cost: 0.03}}
        )
        |> add_tool_call_to_runtime_step("usage_call", "demo__echo", %{"value" => "ok"}, 1)

      %{tool_calls: [_call]} =
        Persistence.persist_provider_completed!(assistant_message.id, runtime_step)

      [waiting_usage] =
        LlmUsageRecord
        |> Ash.Query.filter(chat_message_step_id_snapshot == ^provider_step_id)
        |> Ash.read!(actor: actor)

      assert waiting_usage.status == :waiting_tools
      assert waiting_usage.cost == 0.03

      :ok = Persistence.mark_step_done!(provider_step_id)

      [done_usage] =
        LlmUsageRecord
        |> Ash.Query.filter(chat_message_step_id_snapshot == ^provider_step_id)
        |> Ash.read!(actor: actor)

      assert done_usage.id == waiting_usage.id
      fields = Enum.map(Ash.Resource.Info.attributes(LlmUsageRecord), & &1.name)
      assert Map.take(done_usage, fields) == Map.take(waiting_usage, fields)
    end

    test "persist_step_trace_only! does not create usage records for user messages" do
      %{user: actor} = user_fixture()
      provider = create_provider!(actor, name: "User usage provider")

      configuration =
        create_configuration!(actor, provider: provider, model_name: "user-usage-model")

      chat =
        create!(Chat, :create, %{llm_configuration_id: configuration.id, note: ""}, actor)

      user_message =
        create!(
          ChatMessage,
          :add_message,
          %{
            chat_id: chat.id,
            role: :user,
            status: :done,
            llm_configuration_id: configuration.id,
            token_count: 0
          },
          actor
        )

      step_id =
        Persistence.ensure_step_started!(
          user_message.id,
          1,
          %{"model" => "user-usage-model"},
          []
        )

      runtime_step =
        RuntimeTrace.new_step(
          id: step_id,
          sequence: 1,
          raw_request: %{"model" => "user-usage-model"}
        )
        |> RuntimeTrace.apply_event(
          {:set_step_usage, %{input_tokens: 3, output_tokens: 0, cost: 0.001}}
        )

      :ok = Persistence.persist_step_trace_only!(user_message.id, runtime_step)

      usage_records =
        LlmUsageRecord
        |> Ash.Query.filter(chat_message_step_id_snapshot == ^step_id)
        |> Ash.read!(actor: actor)

      assert usage_records == []
    end

    test "persist_provider_completed! stores provider rows and replaces stale step items" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model", "messages" => []},
          []
        )

      first_runtime_step =
        tool_call_runtime_step(step_id, "call_1", "demo__first", %{"value" => 1})
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "resp_1"}})

      first = Persistence.persist_provider_completed!(assistant_message.id, first_runtime_step)
      [first_call] = first.tool_calls

      assert first.step.status == :waiting_tools
      assert first.step.raw_response == %{"id" => "resp_1"}
      assert first_call.call_id == "call_1"
      assert is_integer(first_call.item_id)

      second_runtime_step =
        tool_call_runtime_step(step_id, "call_2", "demo__second", %{"value" => 2})
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "resp_2"}})

      second = Persistence.persist_provider_completed!(assistant_message.id, second_runtime_step)
      [second_call] = second.tool_calls

      assert second.step.raw_response == %{"id" => "resp_2"}
      assert second_call.call_id == "call_2"
      assert second_call.item_id != first_call.item_id
      assert {:error, _error} = Ash.get(ChatMessageItem, first_call.item_id, actor: actor)
    end

    test "provider trace sequences are shifted past every leading steering item" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model", "messages" => []},
          []
        )

      %{runtime_step: runtime_step} =
        persist_queued_steering!(
          assistant_message,
          step_id,
          "Change direction",
          %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Change direction"}]
          },
          actor
        )

      runtime_step =
        runtime_step
        |> RuntimeTrace.apply_event({:ensure_item, "reasoning", :reasoning, 1})
        |> RuntimeTrace.apply_event({:set_text, "reasoning", :reasoning, 1, "Private reasoning"})
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 2})
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 2, "Final answer"})
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "resp_steered"}})

      %{step: persisted_step} =
        Persistence.persist_provider_completed!(assistant_message.id, runtime_step)

      items = Enum.sort_by(persisted_step.items, & &1.sequence)

      assert Enum.map(items, &{&1.sequence, &1.type}) == [
               {1, :steering},
               {2, :reasoning},
               {3, :answer}
             ]
    end
  end

  describe "terminal partial output" do
    test "cancel keeps durable steering, partial provider output, and usage" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model", "messages" => []},
          []
        )

      %{runtime_step: runtime_step} =
        persist_queued_steering!(
          assistant_message,
          step_id,
          "Do not continue",
          %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Do not continue"}]
          },
          actor
        )

      runtime_step =
        runtime_step
        |> RuntimeTrace.apply_event({:ensure_item, "reasoning", :reasoning, 1})
        |> RuntimeTrace.apply_event({:set_text, "reasoning", :reasoning, 1, "Partial reasoning"})
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 2})
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Partial answer"})
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "partial"}})
        |> RuntimeTrace.apply_event({:set_step_usage, %{input_tokens: 20, output_tokens: 5}})

      :ok = Persistence.persist_canceled!(assistant_message.id, runtime_step)

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:raw_request, :raw_response, items: [:contents]]]
        )

      assert message.status == :canceled
      assert message.token_count > 0
      assert [interrupted, step] = Enum.sort_by(message.steps, & &1.sequence)
      assert interrupted.id == step_id
      assert interrupted.status == :canceled
      refute Enum.any?(interrupted.items, &(&1.type == :answer))
      assert step.id == runtime_step.id
      assert step.id != step_id
      assert step.status == :canceled
      assert step.raw_response == %{"id" => "partial"}
      assert step.input_tokens == 20
      assert step.output_tokens == 5
      assert %DateTime{} = step.first_token_at

      items = Enum.sort_by(step.items, & &1.sequence)
      assert Enum.map(items, & &1.type) == [:steering, :reasoning, :answer]

      assert persisted_item_text(Enum.find(items, &(&1.type == :reasoning))) ==
               "Partial reasoning"

      assert persisted_item_text(Enum.find(items, &(&1.type == :answer))) == "Partial answer"
    end

    test "terminal error keeps partial provider output and usage" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model", "messages" => []},
          []
        )

      runtime_step =
        RuntimeTrace.new_step(
          id: step_id,
          sequence: 1,
          raw_request: %{"model" => "demo-model", "messages" => []}
        )
        |> RuntimeTrace.apply_event({:ensure_item, "reasoning", :reasoning, 1})
        |> RuntimeTrace.apply_event({:set_text, "reasoning", :reasoning, 1, "Partial reasoning"})
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 2})
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Partial answer"})
        |> RuntimeTrace.apply_event({:ensure_item, "error", :error, 3})
        |> RuntimeTrace.apply_event({:set_text, "error", :error, 1, "Stream failed"})
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "partial-error"}})
        |> RuntimeTrace.apply_event({:set_step_usage, %{input_tokens: 30, output_tokens: 7}})

      :ok = Persistence.persist_error!(assistant_message.id, runtime_step, "Stream failed")

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:raw_request, :raw_response, items: [:contents]]]
        )

      assert message.status == :error
      assert message.error_detail == "Stream failed"
      assert message.token_count > 0
      assert [step] = message.steps
      assert step.status == :error
      assert step.raw_response == %{"id" => "partial-error"}
      assert step.input_tokens == 30
      assert step.output_tokens == 7
      assert %DateTime{} = step.first_token_at

      items = Enum.sort_by(step.items, & &1.sequence)
      assert Enum.map(items, & &1.type) == [:reasoning, :answer, :error]

      assert persisted_item_text(Enum.find(items, &(&1.type == :reasoning))) ==
               "Partial reasoning"

      assert persisted_item_text(Enum.find(items, &(&1.type == :answer))) == "Partial answer"
      assert persisted_item_text(Enum.find(items, &(&1.type == :error))) == "Stream failed"
    end

    test "canceling while tools run keeps the durable provider trace and tool results" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model", "messages" => []},
          []
        )

      runtime_step =
        tool_call_runtime_step(step_id, "call_1", "demo__echo", %{"value" => "one"})
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "resp_1"}})

      %{step: provider_step, tool_calls: [call]} =
        Persistence.persist_provider_completed!(assistant_message.id, runtime_step)

      steering_item_id =
        create_archived_steering_item!(step_id, "Keep the completed work", :after_response, actor).id

      result = %{
        text: "tool output",
        result_raw: %{"ok" => true},
        media_contents: [],
        artifact_contents: []
      }

      persisted_result =
        Persistence.persist_tool_result!(assistant_message.id, step_id, call, result)

      :ok = Persistence.persist_canceled_from_step!(assistant_message.id, step_id)

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:raw_request, :raw_response, items: [:contents]]]
        )

      assert message.status == :canceled
      assert [step] = message.steps
      assert step.status == :canceled
      assert step.raw_response == provider_step.raw_response

      items_by_id = Map.new(step.items, &{&1.id, &1})
      assert Map.has_key?(items_by_id, call.item_id)
      assert Map.has_key?(items_by_id, persisted_result.item_id)
      assert Map.has_key?(items_by_id, steering_item_id)

      assert step.items |> Enum.map(& &1.type) |> Enum.sort() == [
               :steering,
               :tool_call,
               :tool_result
             ]
    end
  end

  describe "tool results" do
    test "ChatMessageItem requires a canonical tool call link for new tool result items" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)
      step = create_demo_step!(actor, assistant_message.id, 1)
      answer_item = create_item!(actor, step.id, sequence: 1, type: :answer)
      tool_call_item = create_item!(actor, step.id, sequence: 2, type: :tool_call)

      assert {:error, _error} =
               ChatMessageItem
               |> Ash.Changeset.for_create(
                 :create,
                 %{chat_message_step_id: step.id, sequence: 3, type: :tool_result},
                 actor: actor
               )
               |> Ash.create(actor: actor)

      assert {:error, _error} =
               ChatMessageItem
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   chat_message_step_id: step.id,
                   sequence: 3,
                   type: :tool_result,
                   tool_call_item_id: answer_item.id
                 },
                 actor: actor
               )
               |> Ash.create(actor: actor)

      assert {:ok, result_item} =
               ChatMessageItem
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   chat_message_step_id: step.id,
                   sequence: 3,
                   type: :tool_result,
                   tool_call_item_id: tool_call_item.id
                 },
                 actor: actor
               )
               |> Ash.create(actor: actor)

      assert result_item.tool_call_item_id == tool_call_item.id
    end

    test "ChatMessageItem rejects tool result links to another step" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)
      step_1 = create_demo_step!(actor, assistant_message.id, 1)
      step_2 = create_demo_step!(actor, assistant_message.id, 2)
      other_step_call = create_item!(actor, step_2.id, sequence: 1, type: :tool_call)

      assert {:error, _error} =
               ChatMessageItem
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   chat_message_step_id: step_1.id,
                   sequence: 1,
                   type: :tool_result,
                   tool_call_item_id: other_step_call.id
                 },
                 actor: actor
               )
               |> Ash.create(actor: actor)
    end

    test "persist_tool_result! links results idempotently and list_missing_tool_calls! uses persisted links" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model", "messages" => []},
          []
        )

      runtime_step =
        tool_call_runtime_step(step_id, "call_1", "demo__echo", %{"value" => "one"})
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "resp_1"}})

      %{tool_calls: [call]} =
        Persistence.persist_provider_completed!(assistant_message.id, runtime_step)

      assert %DateTime{} = call.created_at
      assert [missing] = Persistence.list_missing_tool_calls!(step_id)
      assert missing.item_id == call.item_id
      assert missing.created_at == call.created_at

      result = %{
        text: "tool output",
        result_raw: %{"ok" => true},
        media_contents: [],
        artifact_contents: []
      }

      persisted_result =
        Persistence.persist_tool_result!(assistant_message.id, step_id, call, result)

      retry_result = Persistence.persist_tool_result!(assistant_message.id, step_id, call, result)

      assert persisted_result.item_id == retry_result.item_id
      assert persisted_result.tool_call_item_id == call.item_id
      assert persisted_result.responses_item["id"] == retry_result.responses_item["id"]
      assert Persistence.list_missing_tool_calls!(step_id) == []
    end

    test "interruption receipts retain real results and close only missing calls idempotently" do
      %{user: actor} = user_fixture()
      message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(message.id, %{"model" => "demo-model", "messages" => []})

      runtime_step =
        RuntimeTrace.new_step(
          id: step_id,
          sequence: 1,
          raw_request: %{"model" => "demo-model", "messages" => []}
        )
        |> add_tool_call_to_runtime_step("call_1", "tool__safe", %{}, 1)
        |> add_tool_call_to_runtime_step("call_2", "tool__unsafe", %{}, 2)
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "response"}})

      %{tool_calls: [first, second]} =
        Persistence.persist_provider_completed!(message.id, runtime_step)

      {:ok, queued} =
        IntellectualClub.Chat.QueuedMessages.enqueue_steer(message.id, "Change", actor)

      assert Persistence.request_tool_interruptions!(
               message.id,
               step_id,
               &(&1.name == "tool__safe")
             ) == [first.item_id]

      assert {:ok, _} = IntellectualClub.Chat.QueuedMessages.deliver_now(queued.id, actor)

      assert Enum.sort(
               Persistence.request_tool_interruptions!(
                 message.id,
                 step_id,
                 &(&1.name == "tool__safe")
               )
             ) ==
               Enum.sort([first.item_id, second.item_id])

      # A protected result writer wins before the batch has drained.
      original =
        Persistence.persist_tool_result!(message.id, step_id, first, %{
          text: "Already completed",
          result_raw: %{"ok" => true}
        })

      assert :ok = Persistence.finish_tool_interruptions!(message.id, step_id)
      results = Persistence.load_step_for_followup!(step_id).results
      assert [real, interrupted] = results
      assert real.item_id == original.item_id
      assert real.text == "Already completed"

      assert interrupted.result_raw == %{
               "isError" => true,
               "code" => "interrupted_by_steering",
               "outcome" => "unknown"
             }

      assert :ok = Persistence.finish_tool_interruptions!(message.id, step_id)

      assert Enum.map(Persistence.load_step_for_followup!(step_id).results, & &1.item_id) ==
               Enum.map(results, & &1.item_id)

      assert [] == Persistence.list_missing_tool_calls!(step_id)
    end

    test "persist_tool_result! gives parallel tool results non-conflicting stable sequences" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model", "messages" => []},
          []
        )

      runtime_step =
        RuntimeTrace.new_step(
          id: step_id,
          sequence: 1,
          raw_request: %{"model" => "demo-model", "messages" => []}
        )
        |> add_tool_call_to_runtime_step("call_1", "demo__one", %{"value" => 1}, 1)
        |> add_tool_call_to_runtime_step("call_2", "demo__two", %{"value" => 2}, 2)
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "resp_1"}})

      %{tool_calls: tool_calls} =
        Persistence.persist_provider_completed!(assistant_message.id, runtime_step)

      results =
        tool_calls
        |> Task.async_stream(
          fn call ->
            Persistence.persist_tool_result!(assistant_message.id, step_id, call, %{
              text: "tool output #{call.call_id}",
              result_raw: %{"ok" => true},
              media_contents: [],
              artifact_contents: []
            })
          end,
          max_concurrency: 2,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.map(results, & &1.tool_call_item_id) |> Enum.sort() ==
               Enum.map(tool_calls, & &1.item_id) |> Enum.sort()

      assert results |> Enum.map(& &1.sequence) |> Enum.uniq() |> length() == 2
      assert Persistence.list_missing_tool_calls!(step_id) == []
    end

    test "after-response steering survives tool recovery and the next-step transition" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      step_id =
        Persistence.ensure_step_started!(
          assistant_message.id,
          1,
          %{"model" => "demo-model", "messages" => []},
          []
        )

      runtime_step =
        tool_call_runtime_step(step_id, "call_steer", "demo__echo", %{"value" => "one"})
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "resp_steer"}})

      %{tool_calls: [call]} =
        Persistence.persist_provider_completed!(assistant_message.id, runtime_step)

      steering_item_id =
        create_archived_steering_item!(
          step_id,
          "Use the tool result differently",
          :after_response,
          actor
        ).id

      Persistence.persist_tool_result!(assistant_message.id, step_id, call, %{
        text: "tool output",
        result_raw: %{"ok" => true},
        media_contents: [],
        artifact_contents: []
      })

      followup = Persistence.load_step_for_followup!(step_id)

      assert [%{item_id: ^steering_item_id, text: "Use the tool result differently"}] =
               followup.steering_items

      next_request = %{
        "model" => "demo-model",
        "messages" => [%{"role" => "user", "content" => "Use the tool result differently"}]
      }

      transition =
        with_generation_lease(assistant_message.id, fn lease ->
          Persistence.complete_step_and_start_next!(
            assistant_message.id,
            step_id,
            2,
            next_request,
            lease: lease
          )
        end)

      assert transition.step_sequence == 2
      assert transition.raw_request == next_request

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:raw_request, :raw_response, items: [:contents]]]
        )

      [source_step, next_step] = Enum.sort_by(message.steps, & &1.sequence)
      assert source_step.status == :done
      assert next_step.status == :waiting_provider
      assert StepRequests.request_for_step!(next_step.id, actor: actor) == next_request
      assert Enum.any?(source_step.items, &(&1.id == steering_item_id and &1.type == :steering))
    end
  end

  describe "retry replacement" do
    test "replace_steps_for_retry! removes the selected step range and resets the message" do
      %{user: actor} = user_fixture()

      chat =
        create_chat!(actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      assistant_message =
        create!(
          ChatMessage,
          :add_message,
          %{
            chat_id: chat.id,
            role: :assistant,
            parent_id: user_message.id,
            status: :error,
            error_detail: "boom",
            token_count: 123
          },
          actor
        )

      step_1 = create_demo_step!(actor, assistant_message.id, 1)
      {item_1, content_1} = create_answer_with_content!(actor, step_1.id, 1, "step 1")

      step_2 = create_demo_step!(actor, assistant_message.id, 2)
      {item_2, content_2} = create_answer_with_content!(actor, step_2.id, 1, "step 2")

      step_3 = create_demo_step!(actor, assistant_message.id, 3)
      {item_3, content_3} = create_answer_with_content!(actor, step_3.id, 1, "step 3")

      assert {:ok, reservation} = Lease.reserve(assistant_message.id)

      assert {:ok, {fenced, replacement_id}} =
               Lease.claim_and_run_with_chat(
                 reservation,
                 chat.id,
                 [:error],
                 fn operation, fenced ->
                   Persistence.replace_steps_for_retry!(
                     assistant_message.id,
                     2,
                     %{"retry" => true},
                     [],
                     operation,
                     lease: fenced
                   )
                 end,
                 with_lock_scope: fn callback ->
                   LinkedForkCleanup.with_scope(
                     {:steps, assistant_message.id, 2},
                     actor,
                     callback
                   )
                 end
               )

      assert :ok = Lease.release(fenced)

      assert is_integer(replacement_id)
      assert {:ok, _step} = Ash.get(ChatMessageStep, step_1.id, actor: actor)
      assert {:ok, _item} = Ash.get(ChatMessageItem, item_1.id, actor: actor)
      assert {:ok, _content} = Ash.get(ChatMessageContent, content_1.id, actor: actor)

      assert {:error, _error} = Ash.get(ChatMessageStep, step_2.id, actor: actor)
      assert {:error, _error} = Ash.get(ChatMessageStep, step_3.id, actor: actor)
      assert {:error, _error} = Ash.get(ChatMessageItem, item_2.id, actor: actor)
      assert {:error, _error} = Ash.get(ChatMessageItem, item_3.id, actor: actor)
      assert {:error, _error} = Ash.get(ChatMessageContent, content_2.id, actor: actor)
      assert {:error, _error} = Ash.get(ChatMessageContent, content_3.id, actor: actor)

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:raw_request, :raw_response, items: [:contents]]]
        )

      assert message.status == :generating
      assert message.error_detail == nil
      assert message.token_count == 0
      assert message.finished_at == nil
      assert Enum.sort(Enum.map(message.steps || [], & &1.sequence)) == [1, 2]

      replacement = Enum.find(message.steps, &(&1.sequence == 2))
      assert replacement.id == replacement_id
      assert replacement.status == :waiting_provider
      assert replacement.raw_request == %{"retry" => true}
      assert replacement.items == []
    end

    test "retrying a step promotes trailing steering into the retried provider request" do
      %{user: actor} = user_fixture()
      assistant_message = create_generating_assistant_message!(actor)

      raw_request = %{
        "messages" => [%{"role" => "user", "content" => "Original request"}]
      }

      step_id = Persistence.ensure_step_started!(assistant_message.id, 1, raw_request, [])

      trailing_item_id =
        create_archived_steering_item!(step_id, "Apply this on retry", :after_response, actor).id

      step = Ash.get!(ChatMessageStep, step_id, actor: actor)

      _step =
        step
        |> Ash.Changeset.for_update(:update, %{status: :error}, actor: actor)
        |> Ash.update!(actor: actor)

      _message =
        assistant_message
        |> Ash.Changeset.for_update(
          :set_generation_state,
          %{status: :error, error_detail: "retry", token_count: 0},
          actor: actor
        )
        |> Ash.update!(actor: actor)

      assert {:ok, _context} =
               GenerationSupervisor.retry_from_step(assistant_message.id, step_id,
                 actor: actor,
                 chunk_delay_ms: 0
               )

      message =
        wait_for_message_status!(assistant_message.id, actor, :done,
          timeout: 4_000,
          load: [steps: [:raw_request, :raw_response, items: [:contents]]]
        )

      assert [retried_step] = message.steps
      refute Enum.any?(retried_step.items, &(&1.id == trailing_item_id))

      assert List.last(retried_step.raw_request["messages"]) == %{
               "role" => "user",
               "content" => "Apply this on retry"
             }

      steering = Enum.find(retried_step.items, &(&1.type == :steering))

      assert Enum.any?(steering.contents, fn content ->
               content.kind == :opaque and
                 content.content_json == %{"placement" => "before_response"}
             end)
    end
  end

  defp persist_queued_steering!(message, step_id, text, request, actor) do
    assert {:ok, queued} = QueuedMessages.enqueue_steer(message.id, text, actor)
    specs = [%{id: queued.id, text: text, updated_at: queued.updated_at}]

    with_generation_lease(message.id, fn lease ->
      Persistence.persist_queued_steering_before_provider!(
        message.id,
        step_id,
        specs,
        request,
        lease: lease
      )
    end)
  end

  defp create_archived_steering_item!(step_id, text, placement, actor) do
    sequence = if placement == :after_response, do: 2_000_000_000, else: 1
    item = create_item!(actor, step_id, sequence: sequence, type: :steering)

    for attrs <- [
          %{sequence: 1, kind: :text, content_text: text},
          %{
            sequence: 1_000_000,
            kind: :opaque,
            content_text: "",
            content_json: %{"placement" => Atom.to_string(placement)}
          }
        ] do
      ChatMessageContent
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :chat_message_item_id, item.id),
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end

    Ash.get!(ChatMessageItem, item.id, actor: actor, load: [:contents])
  end

  defp create_demo_step!(actor, message_id, sequence) do
    create_step!(actor, message_id,
      sequence: sequence,
      raw_request: %{
        "model" => "demo-model",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "stream" => true
      },
      raw_response: %{},
      response_final: false
    )
  end

  defp create_answer_with_content!(actor, step_id, sequence, text) do
    item = create_item!(actor, step_id, sequence: sequence)
    {item, create_content!(actor, item, content_text: text)}
  end

  defp create_generating_assistant_message!(actor) do
    create_generating_message!(actor, create_chat!(actor), %{token_count: 0})
  end

  defp persisted_item_text(nil), do: ""

  defp persisted_item_text(item) do
    item.contents
    |> Enum.sort_by(& &1.sequence)
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join("", &to_string(&1.content_text || ""))
  end

  defp tool_call_runtime_step(step_id, call_id, name, args) do
    RuntimeTrace.new_step(
      id: step_id,
      sequence: 1,
      raw_request: %{"model" => "demo-model", "messages" => []}
    )
    |> add_tool_call_to_runtime_step(call_id, name, args, 1)
  end

  defp add_tool_call_to_runtime_step(runtime_step, call_id, name, args, sequence) do
    args_json = Jason.encode!(args)

    runtime_step
    |> RuntimeTrace.apply_event({:ensure_item, "tc:" <> call_id, :tool_call, sequence})
    |> RuntimeTrace.apply_event(
      {:set_opaque, "tc:" <> call_id, :tool_call, 10_000,
       %{
         "tool_call_id" => call_id,
         "call_id" => call_id,
         "name" => name,
         "raw" => %{
           "id" => call_id,
           "type" => "function",
           "function" => %{"name" => name, "arguments" => args_json}
         }
       }}
    )
  end
end
