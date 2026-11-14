defmodule IntellectualClub.FilesFixtures do
  @moduledoc """
  Fixtures for stored files, multipart uploads, request image pins, image
  verdicts and provider facts about images.
  """

  import IntellectualClub.Fixtures

  require Ash.Query

  alias IntellectualClub.Chat.ChatMessageStepRequestFile
  alias IntellectualClub.Files.{ImageProviderVerdict, ImageVerdict}

  @legacy_thumbnail_variant "thumbnail:max-edge=2000:preserve-format:v1"

  @doc """
  Stores a file through `IntellectualClub.Files.create_from_upload/1`.
  Defaults: `filename: "file.txt"`, `mime_type: "text/plain"`, `payload: "content"`.
  """
  def create_file!(attrs \\ %{}) do
    defaults = %{filename: "file.txt", mime_type: "text/plain", payload: "content"}
    {:ok, file} = IntellectualClub.Files.create_from_upload(merge_attrs(defaults, attrs))
    file
  end

  @doc """
  Replaces the single request-file pin of `step` (a record or an id) with a
  downscaled rendition as earlier releases created them: variant
  `#{@legacy_thumbnail_variant}` with a payload distinct from the source
  file. Current releases still read, inherit and reuse such pins but no longer
  create them. Returns the new binding with `:file` loaded.
  """
  def pin_legacy_thumbnail!(step, payload, mime_type \\ "image/png") do
    step_id = id_of(step)

    [binding] =
      ChatMessageStepRequestFile
      |> Ash.Query.filter(chat_message_step_id == ^step_id)
      |> Ash.read!(authorize?: false)

    :ok = Ash.destroy!(binding, authorize?: false)
    {:ok, file} = IntellectualClub.Files.create_from_binary("thumbnail.png", mime_type, payload)

    ChatMessageStepRequestFile
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_step_id: step_id,
        file_id: file.id,
        reference_key: binding.reference_key,
        source_file_external_id: binding.source_file_external_id,
        variant_key: @legacy_thumbnail_variant
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
    |> Ash.load!(:file, authorize?: false)
  end

  @doc """
  Writes an image verdict row for `sha256` directly, e.g. a stale or a
  deliberately wrong one. Defaults to a current valid 1x1 PNG verdict.
  """
  def image_verdict!(sha256, attrs \\ %{}) do
    defaults = %{
      sha256: sha256,
      check_version: IntellectualClub.ImageProcessor.check_version(),
      status: :valid,
      mime_type: "image/png",
      width: 1,
      height: 1,
      reason: nil
    }

    ImageVerdict
    |> Ash.Changeset.for_create(:record, Map.merge(defaults, Map.new(attrs)), authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  @doc """
  The provider facts of `sha256` as `%{llm_configuration_id => {status, details}}`,
  read directly.
  """
  def image_provider_verdicts(sha256) do
    ImageProviderVerdict
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.llm_configuration_id, {&1.status, &1.details}})
  end

  @doc """
  Writes `body` to a temporary file and returns a `%Plug.Upload{}` for it, as
  Plug builds for multipart requests. The file is removed when the test exits.
  """
  def plug_upload(filename, content_type, body) do
    safe_name = String.replace(filename, ~r/[^a-zA-Z0-9_.-]/, "_")

    path =
      Path.join(System.tmp_dir!(), "ic-upload-#{System.unique_integer([:positive])}-#{safe_name}")

    File.write!(path, body)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  @doc "Builds a small text PDF with correct object lengths and cross references."
  def text_pdf_fixture(text \\ "Hello PDF needle text", opts \\ []) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("(", "\\(")
      |> String.replace(")", "\\)")

    stream = "BT /F1 18 Tf 72 720 Td (#{escaped}) Tj ET\n"

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}endstream"
    ]

    objects =
      if Keyword.get(opts, :encrypted, false),
        do: objects ++ ["<< /Filter /Standard >>"],
        else: objects

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, id}, {body, offsets} ->
        {body <> "#{id} 0 obj\n#{object}\nendobj\n", offsets ++ [byte_size(body)]}
      end)

    entries =
      Enum.map_join(offsets, "", fn offset ->
        String.pad_leading(Integer.to_string(offset), 10, "0") <> " 00000 n \n"
      end)

    encrypt = if Keyword.get(opts, :encrypted, false), do: " /Encrypt 6 0 R", else: ""

    body <>
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
      entries <>
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R#{encrypt} >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
