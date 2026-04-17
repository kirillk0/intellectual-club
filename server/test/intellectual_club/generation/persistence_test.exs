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

  test "rollback_steps_for_retry! removes the selected step range and resets the message" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Rollback retry", note: "", variables: %{}},
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
        %{title: "Multi-step finished at", note: "", variables: %{}},
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
        %{title: "First token timing", note: "", variables: %{}},
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
end
