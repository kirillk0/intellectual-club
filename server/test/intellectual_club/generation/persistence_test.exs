defmodule IntellectualClub.Generation.PersistenceTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Llm.LlmUsageRecord

  require Ash.Query

  test "rollback_steps_for_retry! removes the selected step range and resets the message" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: chat.id,
          role: :assistant,
          parent_id: user_message.id,
          status: :error,
          error_detail: "boom",
          token_count: 123
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step_1 = create_step!(assistant_message.id, 1, actor)
    {item_1, content_1} = create_text_item!(step_1.id, 1, "step 1", actor)

    step_2 = create_step!(assistant_message.id, 2, actor)
    {item_2, content_2} = create_text_item!(step_2.id, 1, "step 2", actor)

    step_3 = create_step!(assistant_message.id, 3, actor)
    {item_3, content_3} = create_text_item!(step_3.id, 1, "step 3", actor)

    :ok = Persistence.rollback_steps_for_retry!(assistant_message.id, 2)

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
        load: [steps: [items: [:contents]]]
      )

    assert message.status == :generating
    assert message.error_detail == nil
    assert message.token_count == 0
    assert message.finished_at == nil
    assert Enum.map(message.steps || [], & &1.sequence) == [1]
  end

  test "persisted intermediate steps get finished_at while the next step remains open" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

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
        raw_request: %{"model" => "demo-model"}
      )
      |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
      |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Step one"})

    :ok = Persistence.persist_step_trace_only!(assistant_message.id, step_1)

    step_2_id =
      Persistence.ensure_step_started!(
        assistant_message.id,
        2,
        %{
          "model" => "demo-model",
          "messages" => [%{"role" => "assistant", "content" => "Step one"}]
        },
        []
      )

    step_2 =
      RuntimeTrace.new_step(
        id: step_2_id,
        sequence: 2,
        raw_request: %{"model" => "demo-model"}
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

  test "persist_completed! stores first_token_at for the step" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    started_at = ~U[2026-04-16 10:00:00.000000Z]
    first_token_at = ~U[2026-04-16 10:00:00.250000Z]

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
        raw_request: %{"model" => "demo-model"},
        first_token_at: first_token_at,
        output_tokens: 12
      )
      |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
      |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Final answer"})

    :ok = Persistence.persist_completed!(assistant_message.id, runtime_step)

    message =
      Ash.get!(ChatMessage, assistant_message.id,
        actor: actor,
        load: [steps: [:first_token_at, :finished_at]]
      )

    [step] = Enum.sort_by(message.steps || [], & &1.sequence)
    assert step.first_token_at == first_token_at
    assert %DateTime{} = step.finished_at
  end

  test "persist_completed! records durable usage for assistant steps" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor, "Usage provider")
    configuration = create_configuration!(actor, provider, "usage-model")

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          note: ""
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{
          chat_id: chat.id,
          parent_id: user_message.id,
          llm_configuration_id: configuration.id,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

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
        {:set_step_usage, %{input_tokens: 11, output_tokens: 7, cost: 0.015}}
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
  end

  test "persist_step_trace_only! does not create usage records for user messages" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor, "User usage provider")
    configuration = create_configuration!(actor, provider, "user-usage-model")

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{llm_configuration_id: configuration.id, note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    user_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: chat.id,
          role: :user,
          status: :done,
          llm_configuration_id: configuration.id,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

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

  test "ChatMessageItem requires a canonical tool call link for new tool result items" do
    %{user: actor} = user_fixture()
    assistant_message = create_generating_assistant_message!(actor, "Tool result validation")
    step = create_step!(assistant_message.id, 1, actor)
    answer_item = create_item!(step.id, 1, :answer, actor)
    tool_call_item = create_item!(step.id, 2, :tool_call, actor)

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
    assistant_message = create_generating_assistant_message!(actor, "Tool result step validation")
    step_1 = create_step!(assistant_message.id, 1, actor)
    step_2 = create_step!(assistant_message.id, 2, actor)
    other_step_call = create_item!(step_2.id, 1, :tool_call, actor)

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

  test "persist_provider_completed! stores provider rows and replaces stale step items" do
    %{user: actor} = user_fixture()
    assistant_message = create_generating_assistant_message!(actor, "Provider complete")

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

  test "persist_tool_result! links results idempotently and list_missing_tool_calls! uses persisted links" do
    %{user: actor} = user_fixture()
    assistant_message = create_generating_assistant_message!(actor, "Tool result persistence")

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

    assert [missing] = Persistence.list_missing_tool_calls!(step_id)
    assert missing.item_id == call.item_id

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

  test "persist_tool_result! gives parallel tool results non-conflicting stable sequences" do
    %{user: actor} = user_fixture()
    assistant_message = create_generating_assistant_message!(actor, "Parallel tool results")

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

  defp create_step!(message_id, sequence, actor) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_id: message_id,
        sequence: sequence,
        status: :done,
        raw_request: %{
          "model" => "demo-model",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "stream" => true
        },
        raw_response: %{},
        response_final: false
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_text_item!(step_id, sequence, text, actor) do
    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step_id, sequence: sequence, type: :answer},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    content =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: item.id,
          sequence: 1,
          kind: :text,
          content_text: text
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {item, content}
  end

  defp create_generating_assistant_message!(actor, _title) do
    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    ChatMessage
    |> Ash.Changeset.for_create(
      :create_generating_assistant,
      %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_item!(step_id, sequence, type, actor) do
    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_step_id: step_id, sequence: sequence, type: type},
      actor: actor
    )
    |> Ash.create!(actor: actor)
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

  defp create_provider!(actor, name) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        type: :demo,
        auth_method: :api_key,
        base_url: nil,
        api_key: nil
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration!(actor, provider, model_name) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: model_name,
        note: "cfg",
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        context_length: 2048,
        supports_cache_control: false,
        supports_image_input: false
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
