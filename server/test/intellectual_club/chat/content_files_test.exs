defmodule IntellectualClub.Chat.ContentFilesTest do
  @moduledoc """
  Tests for loading file payloads referenced by chat message contents.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat

  alias IntellectualClub.Chat.{
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep,
    ContentFiles
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Tools.ExecutionContext

  test "load_payload_for_execution loads media payload by file external_id within the execution context" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    message = create_message!(chat, actor)
    step = create_step!(message, actor)
    item = create_item!(step, actor)
    {:ok, file} = Files.create_from_binary("sample.txt", "text/plain", sample_payload())
    content = create_media_content!(item, file, actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      assistant_message_id: message.id,
      provider_type: :responses
    }

    assert {:ok, {loaded_content, loaded_file, payload}} =
             ContentFiles.load_payload_for_execution(file.external_id, context)

    assert loaded_content.id == content.id
    assert loaded_content.external_id == content.external_id
    assert loaded_file.id == file.id
    assert loaded_file.external_id == file.external_id
    assert payload == sample_payload()
  end

  test "load_payload_for_execution rejects content external_id even within the execution context" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    message = create_message!(chat, actor)
    step = create_step!(message, actor)
    item = create_item!(step, actor)
    {:ok, file} = Files.create_from_binary("sample.txt", "text/plain", sample_payload())
    content = create_media_content!(item, file, actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      assistant_message_id: message.id,
      provider_type: :responses
    }

    assert {:error, :not_found} =
             ContentFiles.load_payload_for_execution(content.external_id, context)
  end

  test "load_payload_for_execution rejects file external_id outside the execution context" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    message = create_message!(chat, actor)
    step = create_step!(message, actor)
    item = create_item!(step, actor)
    {:ok, file} = Files.create_from_binary("sample.txt", "text/plain", sample_payload())
    _content = create_media_content!(item, file, actor)

    other_chat = create_chat!(actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: other_chat.id,
      message_id: message.id,
      assistant_message_id: message.id,
      provider_type: :responses
    }

    assert {:error, :not_found} =
             ContentFiles.load_payload_for_execution(file.external_id, context)
  end

  test "load_payload_for_execution rejects invalid external_id values" do
    context = %ExecutionContext{owner_id: 1, chat_id: 1}

    assert {:error, :invalid_request} =
             ContentFiles.load_payload_for_execution("not-a-uuid", context)
  end

  defp create_chat!(actor) do
    Chat.Chat
    |> Ash.Changeset.for_create(:create, %{title: "Content files test", note: "", variables: %{}},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_message!(chat, actor) do
    ChatMessage
    |> Ash.Changeset.for_create(
      :add_message,
      %{chat_id: chat.id, role: :assistant, status: :done},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_step!(message, actor) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_id: message.id, sequence: 1, status: :done},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_item!(step, actor) do
    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_step_id: step.id, sequence: 1, type: :artifact},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_media_content!(item, file, actor) do
    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_item_id: item.id, sequence: 1, kind: :media, file_id: file.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp sample_payload do
    "hello from content files"
  end
end
