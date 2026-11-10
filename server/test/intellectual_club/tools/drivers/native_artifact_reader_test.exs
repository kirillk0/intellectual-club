defmodule IntellectualClub.Tools.Drivers.NativeArtifactReaderTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.ChatMessageContent

  alias IntellectualClub.Files
  alias IntellectualClub.Tools.Drivers.NativeArtifactReader
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.DocumentReader

  import IntellectualClub.FilesFixtures,
    only: [text_pdf_fixture: 0, text_pdf_fixture: 2]

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

    {file, context} =
      create_context_file!(actor, "sample.pdf", "application/pdf", text_pdf_fixture())

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
    assert raw["metadata"]["extractor"] == "pdf_text"
    assert raw["file_id"] == file.external_id
    assert raw["pages_total"] >= 1
  end

  test "PDF extraction reports its engine and character truncation" do
    %{user: actor} = user_fixture()

    tool =
      create_tool_instance!(actor,
        type: "native-artifact-reader",
        name: "Artifact Reader",
        config: %{"max_extract_chars" => 5}
      )

    {file, context} =
      create_context_file!(actor, "sample.pdf", "application/pdf", text_pdf_fixture())

    assert {:ok, {text, raw}} =
             NativeArtifactReader.execute(
               tool,
               "read_file",
               %{"file_id" => file.external_id},
               context
             )

    assert text =~ "Hello"
    assert text =~ "truncated"
    assert raw["metadata"]["extractor"] == "pdf_text"
    assert raw["metadata"]["pdf_page_count"] == 1
    assert raw["metadata"]["truncated"] == true
  end

  test "PDF settings above package ceilings are clamped instead of rejecting every document" do
    %{user: actor} = user_fixture()

    tool =
      create_tool_instance!(actor,
        type: "native-artifact-reader",
        name: "Artifact Reader",
        config: %{"max_extract_chars" => 3_000_000, "extract_timeout_seconds" => 180}
      )

    {file, context} =
      create_context_file!(actor, "sample.pdf", "application/pdf", text_pdf_fixture())

    assert {:ok, {text, raw}} =
             NativeArtifactReader.execute(
               tool,
               "read_file",
               %{"file_id" => file.external_id},
               context
             )

    assert text =~ "Hello PDF needle text"
    assert raw["metadata"]["extractor"] == "pdf_text"
  end

  test "encrypted PDFs return an explicit unsupported error" do
    %{user: actor} = user_fixture()
    tool = create_tool_instance!(actor, type: "native-artifact-reader", name: "Artifact Reader")

    {file, context} =
      create_context_file!(
        actor,
        "encrypted.pdf",
        "application/pdf",
        text_pdf_fixture("secret", encrypted: true)
      )

    assert {:error, reason} =
             NativeArtifactReader.execute(
               tool,
               "read_file",
               %{"file_id" => file.external_id},
               context
             )

    assert reason =~ "encrypted"
  end

  @tag :tmp_dir
  test "failed PDF extraction is not cached and a retry can succeed", %{tmp_dir: root} do
    cfg = DocumentReader.config_from_map(%{})
    source = %{"mime_type" => "application/pdf"}

    assert {:error, _} =
             DocumentReader.ensure_cache_ready(root, self(), "document", cfg, fn ->
               {:ok, {text_pdf_fixture("secret", encrypted: true), source}}
             end)

    refute File.exists?(Path.join([root, "document", "READY"]))

    assert {:ok, {dir, meta, false}} =
             DocumentReader.ensure_cache_ready(root, self(), "document", cfg, fn ->
               {:ok, {text_pdf_fixture(), source}}
             end)

    assert meta["metadata"]["extractor"] == "pdf_text"
    assert File.exists?(Path.join(dir, "READY"))

    assert {:ok, {^dir, _meta, true}} =
             DocumentReader.ensure_cache_ready(root, self(), "document", cfg, fn ->
               flunk("A cached document must not load its source again")
             end)
  end

  @tag :tmp_dir
  test "old native PDF cache entries are rebuilt", %{tmp_dir: root} do
    dir = Path.join(root, "document")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "READY"), "ok")

    File.write!(
      Path.join(dir, "meta.json"),
      Jason.encode!(%{"metadata" => %{"extractor" => "pdf_elixide"}})
    )

    cfg = DocumentReader.config_from_map(%{})

    assert {:ok, {^dir, meta, false}} =
             DocumentReader.ensure_cache_ready(root, self(), "document", cfg, fn ->
               {:ok, {text_pdf_fixture(), %{"mime_type" => "application/pdf"}}}
             end)

    assert meta["metadata"]["extractor"] == "pdf_text"
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
