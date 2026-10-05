defmodule IntellectualClub.Tools.Drivers.NativeArtifactReaderTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.ChatMessageContent

  alias IntellectualClub.Files
  alias IntellectualClub.Tools.Drivers.NativeArtifactReader
  alias IntellectualClub.Tools.ExecutionContext

  test "read_file paginates text files available in the execution context" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        type: "native-artifact-reader",
        name: "Artifact Reader",
        config: %{"chunk_size_tokens" => 10}
      )

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

    tool_instance =
      create_tool_instance!(actor,
        type: "native-artifact-reader",
        name: "Artifact Reader",
        config: %{"chunk_size_tokens" => 10}
      )

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

  test "read_file extracts text from PDF artifacts" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        type: "native-artifact-reader",
        name: "Artifact Reader",
        config: %{"chunk_size_tokens" => 10}
      )

    {file, context} = create_context_file!(actor, "sample.pdf", "application/pdf", pdf_payload())

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

    assert text =~ "File: sample.pdf"
    assert text =~ "Hello PDF needle text"
    assert raw["file_id"] == file.external_id
    assert raw["pages_total"] >= 1
  end

  test "read_file extracts paragraphs from DOCX artifacts" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        type: "native-artifact-reader",
        name: "Artifact Reader",
        config: %{"chunk_size_tokens" => 100}
      )

    {file, context} =
      create_context_file!(
        actor,
        "sample.docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        docx_payload()
      )

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

    assert text =~ "File: sample.docx"
    assert text =~ "First DOCX paragraph"
    assert text =~ "Second DOCX needle paragraph"
    assert raw["file_id"] == file.external_id
    assert raw["pages_total"] >= 1
  end

  test "read_image accepts a valid image payload" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, type: "native-artifact-reader", name: "Artifact Reader")

    {file, context} = create_context_file!(actor, "pixel.png", "image/png", png_1x1())

    assert {:ok, result} =
             NativeArtifactReader.execute(
               tool_instance,
               "read_image",
               %{"file_id" => file.external_id},
               context
             )

    assert result.text =~ "Image #{file.external_id}"
    assert [%{file_external_id: file_external_id, mime_type: "image/png"}] = result.media
    assert file_external_id == file.external_id
    assert result.artifacts == []
  end

  test "read_image rejects non-image payloads" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, type: "native-artifact-reader", name: "Artifact Reader")

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

    tool_instance =
      create_tool_instance!(actor, type: "native-artifact-reader", name: "Artifact Reader")

    assert {:ok, result} =
             NativeArtifactReader.execute(tool_instance, "upload_file", %{
               "text" => "saved text",
               "filename" => "../answer.txt"
             })

    assert result.text =~ "File "
    assert [%{file_id: file_id, file_external_id: file_external_id}] = result.artifacts
    assert is_integer(file_id)
    assert is_binary(file_external_id)

    assert {:ok, {file, payload}} = Files.load_payload(file_id)
    assert file.filename == "answer.txt"
    assert file.mime_type == "text/plain"
    assert payload == "saved text"
  end

  defp create_context_file!(actor, filename, mime_type, payload) do
    chat = create_chat!(actor)
    message = create_message!(actor, chat)
    step = create_step!(actor, message)
    item = create_item!(actor, step, type: :artifact)
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

  defp pdf_payload do
    [
      "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIg",
      "MCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBv",
      "YmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvUmVz",
      "b3VyY2VzIDw8IC9Gb250IDw8IC9GMSA0IDAgUiA+PiA+PiAvQ29udGVudHMgNSAwIFIgPj4KZW5kb2Jq",
      "CjQgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNh",
      "ID4+CmVuZG9iago1IDAgb2JqCjw8IC9MZW5ndGggNTMgPj4Kc3RyZWFtCkJUIC9GMSAxOCBUZiA3",
      "MiA3MjAgVGQgKEhlbGxvIFBERiBuZWVkbGUgdGV4dCkgVGogRVQKZW5kc3RyZWFtCmVuZG9iagp4cmVm",
      "CjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAw",
      "MDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAyNDEgMDAwMDAgbiAKMDAwMDAwMDMxMSAw",
      "MDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDYgL1Jvb3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjQxMwolJUVP",
      "Rgo="
    ]
    |> IO.iodata_to_binary()
    |> Base.decode64!()
  end

  defp docx_payload do
    document_xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>First DOCX paragraph</w:t></w:r>
        </w:p>
        <w:p>
          <w:r><w:t>Second DOCX </w:t></w:r>
          <w:r><w:t>needle paragraph</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>
    """

    {:ok, {_name, bytes}} =
      :zip.create(~c"sample.docx", [{~c"word/document.xml", document_xml}], [:memory])

    bytes
  end
end
