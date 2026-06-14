defmodule IntellectualClub.Tools.Drivers.NativeArtifactReaderTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat

  alias IntellectualClub.Chat.{
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Tools.DriverMetadata
  alias IntellectualClub.Tools.Drivers.NativeArtifactReader
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ToolInstance

  test "exposes fixed artifact reader functions" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    names =
      tool_instance
      |> NativeArtifactReader.fixed_functions()
      |> Enum.map(&Map.get(&1, "name"))

    assert names == ["read_file", "search_file", "read_image", "upload_file"]
  end

  test "driver metadata exposes default config and fixed functions" do
    metadata = DriverMetadata.for_type("native-artifact-reader")

    assert metadata["type"] == "native-artifact-reader"
    assert metadata["title"] == "Artifact Reader"
    assert metadata["functions_mode"] == "fixed"
    assert metadata["supports_artifacts"] == true
    assert metadata["default_config"]["chunk_size_tokens"] == 5_000

    assert metadata["fixed_functions"]
           |> Enum.map(& &1["name"])
           |> Enum.sort() == ["read_file", "read_image", "search_file", "upload_file"]
  end

  test "read_file paginates text files available in the execution context" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor, %{"chunk_size_tokens" => 10})
    {file, context} = create_context_file!(actor, "notes.txt", "text/plain", long_text())

    assert {:ok, {text, raw}} =
             NativeArtifactReader.execute(
               tool_instance,
               "read_file",
               %{
                 "file_id" => file.external_id,
                 "page" => 1
               },
               context
             )

    assert text =~ "File: notes.txt"
    assert text =~ "Page: 1 /"
    assert text =~ "alpha"
    assert raw["file_id"] == file.external_id
    assert raw["pages_total"] >= 2
  end

  test "search_file returns snippets and match pages" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor, %{"chunk_size_tokens" => 10})
    {file, context} = create_context_file!(actor, "notes.txt", "text/plain", long_text())

    assert {:ok, {text, raw}} =
             NativeArtifactReader.execute(
               tool_instance,
               "search_file",
               %{
                 "file_id" => file.external_id,
                 "regex" => "needle",
                 "snippet_len_chars" => 80
               },
               context
             )

    assert text =~ "Regex: /needle/"
    assert text =~ "Match pages:"
    assert raw["match_pages"] != []
    assert [%{"snippet" => snippet} | _] = raw["snippets"]
    assert snippet =~ "needle"
  end

  test "read_image accepts a valid image payload" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)
    {file, context} = create_context_file!(actor, "pixel.png", "image/png", image_payload())

    assert {:ok, result} =
             NativeArtifactReader.execute(
               tool_instance,
               "read_image",
               %{"file_id" => file.external_id},
               context
             )

    assert result.text =~ "Image #{file.external_id}"
    assert [%{"file_external_id" => file_external_id, "mime_type" => "image/png"}] = result.media
    assert file_external_id == file.external_id
    assert result.artifacts == []
  end

  test "read_image rejects non-image payloads" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)
    {file, context} = create_context_file!(actor, "notes.txt", "text/plain", "not an image")

    assert {:error, "File content is not a valid image."} =
             NativeArtifactReader.execute(
               tool_instance,
               "read_image",
               %{"file_id" => file.external_id},
               context
             )
  end

  test "upload_file creates a text artifact" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    assert {:ok, result} =
             NativeArtifactReader.execute(tool_instance, "upload_file", %{
               "text" => "saved text",
               "filename" => "../answer.txt"
             })

    assert result.text =~ "File "
    assert [%{"file_id" => file_id, "file_external_id" => file_external_id}] = result.artifacts
    assert is_integer(file_id)
    assert is_binary(file_external_id)

    assert {:ok, {file, payload}} = Files.load_payload(file_id)
    assert file.filename == "answer.txt"
    assert file.mime_type == "text/plain"
    assert payload == "saved text"
  end

  test "validates required arguments and execution context" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    assert {:error, "Execution context is required for read_file."} =
             NativeArtifactReader.execute(tool_instance, "read_file", %{
               "file_id" => Ash.UUID.generate()
             })

    context = %ExecutionContext{owner_id: actor.id, chat_id: 1}

    assert {:error, "Argument `file_id` is required."} =
             NativeArtifactReader.execute(tool_instance, "read_file", %{}, context)

    assert {:error, "Argument `file_id` must be a valid UUID."} =
             NativeArtifactReader.execute(
               tool_instance,
               "read_file",
               %{"file_id" => "bad"},
               context
             )

    assert {:error, "Argument `page` must be a non-negative integer (1-based)."} =
             NativeArtifactReader.execute(
               tool_instance,
               "read_file",
               %{"file_id" => Ash.UUID.generate(), "page" => -1},
               context
             )

    assert {:error, message} =
             NativeArtifactReader.execute(
               tool_instance,
               "search_file",
               %{"file_id" => Ash.UUID.generate(), "regex" => "["},
               context
             )

    assert String.starts_with?(message, "Invalid regex:")
  end

  test "detect_image_mime returns detected mime type for valid image payload" do
    assert {:ok, "image/png"} = NativeArtifactReader.detect_image_mime(image_payload())
  end

  defp create_tool_instance!(actor, config \\ %{}) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-artifact-reader",
        name: "Artifact Reader",
        config: config,
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_context_file!(actor, filename, mime_type, payload) do
    chat = create_chat!(actor)
    message = create_message!(chat, actor)
    step = create_step!(message, actor)
    item = create_item!(step, actor)
    {:ok, file} = Files.create_from_binary(filename, mime_type, payload)
    _content = create_media_content!(item, file, actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      assistant_message_id: message.id,
      provider_type: :responses
    }

    {file, context}
  end

  defp create_chat!(actor) do
    Chat.Chat
    |> Ash.Changeset.for_create(
      :create,
      %{note: ""},
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

  defp long_text do
    """
    alpha beta gamma delta epsilon zeta eta theta iota kappa

    lambda mu nu xi omicron pi rho sigma tau upsilon needle phi chi psi omega

    final paragraph with more words to force another page
    """
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
