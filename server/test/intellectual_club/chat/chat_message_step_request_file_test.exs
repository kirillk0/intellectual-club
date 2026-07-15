defmodule IntellectualClub.Chat.ChatMessageStepRequestFileTest do
  @moduledoc """
  Tests for compact-request file bindings and their lifecycle.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat

  alias IntellectualClub.Chat.{
    ChatMessage,
    ChatMessageStep,
    ChatMessageStepRequestFile
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage

  test "step destroy cascades request bindings and deletes only their logical files" do
    %{user: actor} = user_fixture()
    step = create_step!(actor)
    {:ok, source_file} = Files.create_from_binary("source.png", "image/png", "image payload")
    {:ok, request_file} = Files.duplicate_file(source_file.id)

    binding =
      create_binding!(step, request_file,
        reference_key: source_file.external_id,
        source_file_external_id: source_file.external_id
      )

    loaded_step = Ash.load!(step, :request_files, actor: actor)
    assert Enum.map(loaded_step.request_files, & &1.id) == [binding.id]

    Ash.destroy!(step, actor: actor)

    assert {:error, _error} =
             Ash.get(ChatMessageStepRequestFile, binding.id, authorize?: false)

    assert {:error, _error} = Ash.get(StoredFile, request_file.id, authorize?: false)
    assert Ash.get!(StoredFile, source_file.id, authorize?: false).id == source_file.id
    assert FilesystemStorage.exists?(source_file.sha256)

    assert :ok = Files.delete_file_and_maybe_payload(source_file.id)
    refute FilesystemStorage.exists?(source_file.sha256)
  end

  test "bindings enforce one reference per step and exclusive logical file ownership" do
    %{user: actor} = user_fixture()
    first_step = create_step!(actor)
    second_step = create_step!(actor)
    {:ok, first_file} = Files.create_from_binary("first.png", "image/png", "first payload")
    {:ok, second_file} = Files.create_from_binary("second.png", "image/png", "second payload")
    reference_key = Ash.UUID.generate()

    first_binding =
      create_binding!(first_step, first_file,
        reference_key: reference_key,
        source_file_external_id: first_file.external_id
      )

    assert {:error, _error} =
             create_binding(first_step, second_file,
               reference_key: reference_key,
               source_file_external_id: second_file.external_id
             )

    assert {:error, _error} =
             create_binding(second_step, first_file,
               reference_key: Ash.UUID.generate(),
               source_file_external_id: first_file.external_id
             )

    Ash.destroy!(first_binding, authorize?: false)
    assert :ok = Files.delete_file_and_maybe_payload(second_file.id)
  end

  test "binding destroy rolls back when its owned payload cannot be deleted" do
    %{user: actor} = user_fixture()
    step = create_step!(actor)
    payload = "strict cleanup payload"

    {:ok, request_file} =
      Files.create_from_binary("request.bin", "application/octet-stream", payload)

    binding =
      create_binding!(step, request_file,
        reference_key: request_file.external_id,
        source_file_external_id: request_file.external_id
      )

    {:ok, payload_path} = FilesystemStorage.path_for(request_file.sha256)
    File.rm!(payload_path)
    File.mkdir!(payload_path)
    File.write!(Path.join(payload_path, "sentinel"), "not removable as a blob")

    assert {:error, _error} = Ash.destroy(binding, authorize?: false)
    assert Ash.get!(ChatMessageStepRequestFile, binding.id, authorize?: false).id == binding.id
    assert Ash.get!(StoredFile, request_file.id, authorize?: false).id == request_file.id

    assert {:error, _error} = Ash.destroy(step, actor: actor)
    assert Ash.get!(ChatMessageStep, step.id, actor: actor).id == step.id

    File.rm_rf!(payload_path)
    assert {:ok, :created} = FilesystemStorage.store(request_file.sha256, payload)

    Ash.destroy!(step, actor: actor)
    assert {:error, _error} = Ash.get(ChatMessageStepRequestFile, binding.id, authorize?: false)
    assert {:error, _error} = Ash.get(StoredFile, request_file.id, authorize?: false)
    refute FilesystemStorage.exists?(request_file.sha256)
  end

  defp create_step!(actor) do
    chat =
      Chat.Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{chat_id: chat.id, role: :assistant, status: :done},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_id: message.id, sequence: 1, status: :done},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_binding!(step, file, attrs) do
    step
    |> create_binding(file, attrs)
    |> case do
      {:ok, binding} -> binding
      {:error, error} -> raise error
    end
  end

  defp create_binding(step, file, attrs) do
    ChatMessageStepRequestFile
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_step_id: step.id,
        file_id: file.id,
        reference_key: Keyword.fetch!(attrs, :reference_key),
        source_file_external_id: Keyword.fetch!(attrs, :source_file_external_id),
        variant_key: "identity:v1"
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end
end
