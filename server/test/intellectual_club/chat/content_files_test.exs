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

  test "file references grant access only through owned tool receipts to owned artifacts" do
    %{user: actor} = user_fixture()
    %{user: other_actor} = user_fixture()
    source = create_tool_call_anchor!(actor)
    foreign_source = create_tool_call_anchor!(other_actor)
    {:ok, file} = Files.create_from_binary("local.txt", "text/plain", sample_payload())
    {:ok, foreign_file} = Files.create_from_binary("foreign.txt", "text/plain", "private")
    source_item = create_item!(actor, source.step, sequence: 2, type: :artifact)
    foreign_item = create_item!(other_actor, foreign_source.step, sequence: 2, type: :artifact)
    create_content!(actor, source_item, kind: :media, file_id: file.id)
    create_content!(other_actor, foreign_item, kind: :media, file_id: foreign_file.id)
    receiving = create_tool_call_anchor!(actor)

    receipt =
      create_item!(actor, receiving.step,
        sequence: 2,
        type: :tool_result,
        tool_call_item_id: receiving.item.id
      )

    context = %ExecutionContext{owner_id: actor.id, chat_id: receiving.chat.id}

    metadata =
      create_content!(actor, receipt,
        kind: :opaque,
        content_json: %{"raw" => %{"file_references" => [file.external_id]}}
      )

    assert {:error, :not_found} =
             ContentFiles.load_payload_for_execution(file.external_id, context)

    metadata
    |> Ash.Changeset.for_update(
      :update,
      %{
        content_json: %{"file_references" => [file.external_id, foreign_file.external_id]}
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)

    assert {:ok, {_content, _file, payload}} =
             ContentFiles.load_payload_for_execution(file.external_id, context)

    assert payload == sample_payload()

    assert {:error, :not_found} =
             ContentFiles.load_payload_for_execution(foreign_file.external_id, context)

    assert {:error, :not_found} =
             ContentFiles.load_path_for_execution(foreign_file.external_id, context)

    assert {:error, :not_found} =
             ContentFiles.load_payload_for_execution(
               file.external_id,
               %{context | owner_id: other_actor.id}
             )

    unrelated = create_tool_call_anchor!(actor)
    answer = create_item!(actor, unrelated.step, sequence: 2, type: :answer)

    create_content!(actor, answer,
      kind: :opaque,
      content_json: %{"file_references" => [file.external_id]}
    )

    assert {:error, :not_found} =
             ContentFiles.load_payload_for_execution(
               file.external_id,
               %{context | chat_id: unrelated.chat.id}
             )
  end

  defp sample_payload do
    "hello from content files"
  end
end
