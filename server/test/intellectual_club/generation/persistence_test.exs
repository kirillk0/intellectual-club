defmodule IntellectualClub.Generation.PersistenceTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence

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
    assert Enum.map(message.steps || [], & &1.sequence) == [1]
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
