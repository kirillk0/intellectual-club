defmodule IntellectualClub.Chat.MessageTreeCopyRequestFilesTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat

  alias IntellectualClub.Chat.{
    BranchMove,
    ChatMessage,
    ChatMessageStep,
    ChatMessageStepRequestFile,
    MessageTreeCopy,
    Threads
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Files.GarbageCollector
  alias IntellectualClub.Generation.RequestImages

  require Ash.Query

  test "continue action materializes before create and clones compact request bindings" do
    %{user: actor} = user_fixture()

    %{chat: source, step: source_step, file: canonical_file} =
      create_source_with_request!(actor, image_payload())

    assert request_bindings(source_step.id) == []
    refute Repo.in_transaction?()

    changeset =
      Chat
      |> Ash.Changeset.for_create(:continue, %{id: source.id}, actor: actor)

    refute Repo.in_transaction?()
    assert changeset.valid?

    source_bindings = request_bindings(source_step.id)

    assert length(source_bindings) == 1,
           inspect(Ash.get!(ChatMessageStep, source_step.id, actor: actor).raw_request)

    [source_binding] = source_bindings
    compact_source_step = Ash.get!(ChatMessageStep, source_step.id, actor: actor)

    assert compact_source_step.raw_request == source_step.raw_request
    assert source_binding.reference_key == canonical_file.external_id

    target = Ash.create!(changeset, actor: actor)

    [target_message] =
      Threads.active_branch(target, actor,
        load: MessageTreeCopy.load_spec(),
        strict?: true
      )

    [target_step] = target_message.steps
    [target_binding] = request_bindings(target_step.id)

    assert target_step.raw_request == compact_source_step.raw_request
    assert target_binding.reference_key == source_binding.reference_key
    assert target_binding.source_file_external_id == source_binding.source_file_external_id
    assert target_binding.variant_key == source_binding.variant_key
    assert target_binding.file_id != source_binding.file_id
    assert target_binding.file.sha256 == source_binding.file.sha256

    Ash.destroy!(target, actor: actor)
    Ash.destroy!(source, actor: actor)

    assert {:ok, :deleted} = GarbageCollector.collect_sha256(canonical_file.sha256)
    refute FilesystemStorage.exists?(canonical_file.sha256)
  end

  test "preflight keeps an oversized rendition owned when a later copy rolls back" do
    %{user: actor} = user_fixture()

    %{chat: source, step: source_step} =
      create_source_with_request!(actor, oversized_png_payload())

    source_branch =
      Threads.active_branch(source.id, actor,
        load: MessageTreeCopy.load_spec(),
        strict?: true
      )

    assert {:ok, ^source_branch} =
             MessageTreeCopy.materialize_loaded_messages(source_branch, actor)

    source_bindings = request_bindings(source_step.id)

    assert length(source_bindings) == 1,
           inspect(Ash.get!(ChatMessageStep, source_step.id, actor: actor).raw_request)

    [source_binding] = source_bindings
    rendition_file = Ash.get!(StoredFile, source_binding.file_id, authorize?: false)

    assert source_binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
    assert FilesystemStorage.exists?(rendition_file.sha256)

    target = create_empty_chat!(actor)
    parent = self()

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               MessageTreeCopy.copy_messages!(source_branch, target, actor)

               [copied_message] = messages_for_chat(target.id, actor)
               [copied_step] = copied_message.steps
               [copied_binding] = request_bindings(copied_step.id)
               send(parent, {:rolled_back_request_file_id, copied_binding.file_id})

               Repo.rollback(:forced_rollback)
             end)

    assert_receive {:rolled_back_request_file_id, rolled_back_file_id}
    assert messages_for_chat(target.id, actor) == []
    assert {:error, _error} = Ash.get(StoredFile, rolled_back_file_id, authorize?: false)

    assert Ash.get!(StoredFile, source_binding.file_id, authorize?: false).id ==
             source_binding.file_id

    assert FilesystemStorage.exists?(rendition_file.sha256)
    assert [persisted_binding] = request_bindings(source_step.id)
    assert persisted_binding.file_id == source_binding.file_id

    Ash.destroy!(target, actor: actor)
    Ash.destroy!(source, actor: actor)

    assert {:ok, :deleted} = GarbageCollector.collect_sha256(rendition_file.sha256)
    refute FilesystemStorage.exists?(rendition_file.sha256)
  end

  test "branch move pins request files before their canonical source stays behind" do
    %{user: actor} = user_fixture()
    source = create_empty_chat!(actor)
    {:ok, canonical_file} = Files.create_from_binary("source.png", "image/png", image_payload())

    {:ok, root} =
      Threads.add_message_to_end(source, :user, "",
        actor: actor,
        contents: [%{kind: :media, file_id: canonical_file.id}]
      )

    {:ok, moved} =
      Threads.add_message(source, :assistant, "Moved", actor: actor, parent_id: root.id)

    moved_step = put_request_marker!(moved, canonical_file, actor)

    {:ok, kept} =
      Threads.add_message(source, :assistant, "Kept", actor: actor, parent_id: root.id)

    {:ok, _meta} = Threads.activate_branch(source.id, kept.id, actor)
    assert request_bindings(moved_step.id) == []

    assert {:ok, %{chat: target}} =
             BranchMove.move_branch_to_new_chat(source.id, moved.id, actor)

    [moved_binding] = request_bindings(moved_step.id)
    moved_step = Ash.get!(ChatMessageStep, moved_step.id, actor: actor)

    assert Ash.get!(ChatMessage, moved.id, actor: actor).chat_id == target.id
    assert moved_binding.source_file_external_id == canonical_file.external_id

    Ash.destroy!(source, actor: actor)

    assert {:ok, hydrated_request} = RequestImages.hydrate(moved_step.raw_request, moved_step.id)
    assert inspect(hydrated_request) =~ "data:image/png;base64,"
    assert FilesystemStorage.exists?(moved_binding.file.sha256)

    Ash.destroy!(target, actor: actor)
    assert {:ok, :deleted} = GarbageCollector.collect_sha256(moved_binding.file.sha256)
    refute FilesystemStorage.exists?(moved_binding.file.sha256)
  end

  defp create_source_with_request!(actor, payload) do
    chat = create_empty_chat!(actor)
    {:ok, file} = Files.create_from_binary("source.png", "image/png", payload)

    {:ok, message} =
      Threads.add_message_to_end(chat, :user, "",
        actor: actor,
        contents: [%{kind: :media, file_id: file.id}]
      )

    step = put_request_marker!(message, file, actor)

    %{chat: chat, message: message, step: step, file: file}
  end

  defp put_request_marker!(message, file, actor) do
    step =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^message.id)
      |> Ash.read_one!(actor: actor)

    marker = RequestImages.marker(to_string(file.external_id), "image/png")

    raw_request = %{
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => marker}]
        }
      ]
    }

    step
    |> Ash.Changeset.for_update(:update, %{raw_request: raw_request}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp create_empty_chat!(actor) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, %{note: ""}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp request_bindings(step_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:file)
    |> Ash.read!(authorize?: false)
  end

  defp messages_for_chat(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:steps)
    |> Ash.read!(actor: actor)
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  defp oversized_png_payload do
    assert {:ok, image} = Image.new(3_000, 1_500)
    assert {:ok, payload} = Image.write(image, :memory, suffix: ".png")
    payload
  end
end
