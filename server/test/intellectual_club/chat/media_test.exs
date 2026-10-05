defmodule IntellectualClub.Chat.MediaTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Files

  test "chat message projection emits a placeholder and compact image marker" do
    content = image_content!(png_1x1(), "image/png")

    assert [
             %{"type" => "text", "text" => placeholder},
             %{"type" => "image_url", "image_url" => %{"url" => marker}}
           ] =
             Media.chat_message_content([content],
               supports_image_input: true,
               provider_type: "openrouter_chat_completion"
             )

    assert String.contains?(placeholder, "file_id=")
    assert_image_marker(marker, content.file, "data_url")
    refute inspect(marker) =~ ";base64,"
  end

  test "responses projection emits a placeholder and compact image marker" do
    content = image_content!(png_1x1(), "image/png")

    assert [
             %{"type" => "input_text", "text" => placeholder},
             %{"type" => "input_image", "image_url" => marker}
           ] =
             Media.responses_message_content([content],
               supports_image_input: true,
               provider_type: "responses"
             )

    assert String.contains?(placeholder, "file_id=")
    assert_image_marker(marker, content.file, "data_url")
    refute inspect(marker) =~ ";base64,"
  end

  test "projection defers image validation and resizing until a request step exists" do
    invalid = image_content!("<html><body>404 Not Found</body></html>", "image/png")
    oversized = image_content!(oversized_png(), "image/png")

    for content <- [invalid, oversized] do
      assert [
               %{"type" => "text"},
               %{"type" => "image_url", "image_url" => %{"url" => marker}}
             ] =
               Media.chat_message_content([content],
                 supports_image_input: true,
                 provider_type: "openrouter_chat_completion"
               )

      assert_image_marker(marker, content.file, "data_url")
    end

    assert_original_image(oversized, "image/png", 3_000, 1_500)
  end

  test "non-image media remains a text placeholder" do
    content = image_content!("plain text", "text/plain", "attached.txt")

    assert text =
             Media.chat_message_content([content],
               supports_image_input: true,
               provider_type: "openrouter_chat_completion"
             )

    assert is_binary(text)
    assert String.contains?(text, "[Attached file")
  end

  test "media helpers require canonical atom keys and integer metadata" do
    refute Media.media_content?(%{"kind" => "media"})

    descriptor =
      Media.media_descriptor(%{
        kind: :media,
        external_id: "content-123",
        file_id: "42",
        file: %{
          external_id: "file-123",
          filename: "attachment.png",
          mime_type: "image/png",
          size_bytes: "128",
          sha256: "sha256"
        }
      })

    assert descriptor.file_id == nil
    assert descriptor.size_bytes == 0
  end

  defp image_content!(payload, mime_type, filename \\ "attached.png") do
    assert {:ok, file} =
             Files.create_from_upload(%{
               filename: filename,
               mime_type: mime_type,
               payload: payload
             })

    %{
      sequence: 1,
      kind: :media,
      external_id: "content-123",
      file_id: file.id,
      file: file
    }
  end

  defp assert_image_marker(marker, file, encoding) do
    assert %{
             "$intellectual_club_file" => %{
               "version" => 1,
               "reference_key" => reference_key,
               "source_file_external_id" => source_file_external_id,
               "rendition" => %{
                 "kind" => "fit",
                 "max_edge_px" => 2_000,
                 "format" => "preserve"
               },
               "encoding" => ^encoding,
               "mime_type" => mime_type
             }
           } = marker

    assert reference_key == to_string(file.external_id)
    assert source_file_external_id == to_string(file.external_id)
    assert mime_type == file.mime_type
  end

  defp assert_original_image(content, expected_mime_type, expected_width, expected_height) do
    assert {:ok, {_file, payload}} = Files.load_payload(content.file_id)

    assert {^expected_mime_type, ^expected_width, ^expected_height, _variant} =
             ExImageInfo.info(payload)
  end
end
