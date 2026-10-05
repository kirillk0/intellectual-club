defmodule IntellectualClub.Chat.ContentFilesTest do
  @moduledoc """
  Tests for loading file payloads referenced by chat message contents.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.ContentFiles
  alias IntellectualClub.Files
  alias IntellectualClub.Tools.ExecutionContext

  test "load_payload_for_execution loads media payload by file external_id within the execution context" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    message = create_message!(actor, chat)
    step = create_step!(actor, message)
    item = create_item!(actor, step, type: :artifact)
    {:ok, file} = Files.create_from_binary("sample.txt", "text/plain", sample_payload())
    content = create_content!(actor, item, kind: :media, file_id: file.id)

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
    message = create_message!(actor, chat)
    step = create_step!(actor, message)
    item = create_item!(actor, step, type: :artifact)
    {:ok, file} = Files.create_from_binary("sample.txt", "text/plain", sample_payload())
    content = create_content!(actor, item, kind: :media, file_id: file.id)

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
    message = create_message!(actor, chat)
    step = create_step!(actor, message)
    item = create_item!(actor, step, type: :artifact)
    {:ok, file} = Files.create_from_binary("sample.txt", "text/plain", sample_payload())
    _content = create_content!(actor, item, kind: :media, file_id: file.id)

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

  test "load_payload_for_execution loads media payload from handoff ancestor chat" do
    %{user: actor} = user_fixture()
    parent_chat = create_chat!(actor)
    parent_message = create_message!(actor, parent_chat)
    step = create_step!(actor, parent_message)
    item = create_item!(actor, step, type: :artifact)
    {:ok, file} = Files.create_from_binary("ancestor.txt", "text/plain", sample_payload())
    content = create_content!(actor, item, kind: :media, file_id: file.id)

    child_chat =
      create_subchat!(actor, parent_chat, :handoff, %{
        parent_message_id: parent_message.id,
        subagent: false
      })

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: child_chat.id,
      message_id: parent_message.id,
      assistant_message_id: parent_message.id,
      provider_type: :responses
    }

    assert {:ok, {loaded_content, loaded_file, payload}} =
             ContentFiles.load_payload_for_execution(file.external_id, context)

    assert loaded_content.id == content.id
    assert loaded_file.id == file.id
    assert payload == sample_payload()
  end

  test "load_payload_for_execution accepts explicitly available stored file external_id" do
    %{user: actor} = user_fixture()
    {:ok, file} = Files.create_from_binary("knowledge.txt", "text/plain", sample_payload())

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: -1,
      available_file_external_ids: [file.external_id]
    }

    assert {:ok, {nil, loaded_file, payload}} =
             ContentFiles.load_payload_for_execution(file.external_id, context)

    assert loaded_file.id == file.id
    assert payload == sample_payload()
  end

  test "load_payload_for_execution rejects invalid external_id values" do
    context = %ExecutionContext{owner_id: 1, chat_id: 1}

    assert {:error, :invalid_request} =
             ContentFiles.load_payload_for_execution("not-a-uuid", context)
  end

  defp sample_payload do
    "hello from content files"
  end
end
