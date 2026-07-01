defmodule IntellectualClub.Chat.MediaTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Files

  test "chat_message_content emits placeholder and native image block for valid images" do
    content = image_content!(image_payload(), "image/png")

    assert [
             %{"type" => "text", "text" => placeholder},
             %{"type" => "image_url", "image_url" => %{"url" => data_url}}
           ] =
             Media.chat_message_content([content],
               supports_image_input: true,
               provider_type: :openrouter_chat_completion
             )

    assert String.contains?(placeholder, "file_id=")
    assert String.starts_with?(data_url, "data:image/png;base64,")
    assert_data_url_image(data_url, "image/png", 1, 1)
  end

  test "chat_message_content downsizes oversized native image blocks" do
    content = image_content!(oversized_png_payload(), "image/png")

    assert [
             %{"type" => "text", "text" => placeholder},
             %{"type" => "image_url", "image_url" => %{"url" => data_url}}
           ] =
             Media.chat_message_content([content],
               supports_image_input: true,
               provider_type: :openrouter_chat_completion
             )

    assert String.contains?(placeholder, "file_id=")
    assert_data_url_image(data_url, "image/png", 2_000, 1_000)
    assert_original_image(content, "image/png", 3_000, 1_500)
  end

  test "chat_message_content falls back to explicit text for invalid stored images" do
    content = image_content!("<html><body>404 Not Found</body></html>", "image/png")

    assert content_text =
             Media.chat_message_content([content],
               supports_image_input: true,
               provider_type: :openrouter_chat_completion
             )

    assert is_binary(content_text)
    assert String.contains?(content_text, "[Attached file")

    assert String.contains?(
             content_text,
             "[Image omitted: attached file could not be validated as an image.]"
           )
  end

  test "chat_message_content omits oversized image blocks when resizing fails" do
    content = image_content!(oversized_bmp_header_payload(), "image/bmp", "attached.bmp")

    assert content_text =
             Media.chat_message_content([content],
               supports_image_input: true,
               provider_type: :openrouter_chat_completion
             )

    assert is_binary(content_text)
    assert String.contains?(content_text, "[Attached file")

    assert String.contains?(
             content_text,
             "[Image omitted: attached image exceeded the native image size limit and could not be resized.]"
           )
  end

  test "responses_message_content emits placeholder and native image block for valid images" do
    content = image_content!(image_payload(), "image/png")

    assert [
             %{"type" => "input_text", "text" => placeholder},
             %{"type" => "input_image", "image_url" => data_url}
           ] =
             Media.responses_message_content([content],
               supports_image_input: true,
               provider_type: :responses
             )

    assert String.contains?(placeholder, "file_id=")
    assert String.starts_with?(data_url, "data:image/png;base64,")
    assert_data_url_image(data_url, "image/png", 1, 1)
  end

  test "responses_message_content downsizes oversized native image blocks" do
    content = image_content!(oversized_png_payload(), "image/png")

    assert [
             %{"type" => "input_text", "text" => placeholder},
             %{"type" => "input_image", "image_url" => data_url}
           ] =
             Media.responses_message_content([content],
               supports_image_input: true,
               provider_type: :responses
             )

    assert String.contains?(placeholder, "file_id=")
    assert_data_url_image(data_url, "image/png", 2_000, 1_000)
  end

  test "responses_message_content omits native image block and adds explicit fallback text for invalid images" do
    content = image_content!("<html><body>404 Not Found</body></html>", "image/png")

    assert [
             %{"type" => "input_text", "text" => placeholder},
             %{"type" => "input_text", "text" => fallback}
           ] =
             Media.responses_message_content([content],
               supports_image_input: true,
               provider_type: :responses
             )

    assert String.contains?(placeholder, "[Attached file")
    assert fallback == "[Image omitted: attached file could not be validated as an image.]"
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

  defp assert_data_url_image(data_url, expected_mime_type, expected_width, expected_height) do
    assert {^expected_mime_type, payload} = decode_data_url(data_url)

    assert {^expected_mime_type, ^expected_width, ^expected_height, _variant} =
             ExImageInfo.info(payload)
  end

  defp assert_original_image(content, expected_mime_type, expected_width, expected_height) do
    assert {:ok, {_file, payload}} = Files.load_payload(content.file_id)

    assert {^expected_mime_type, ^expected_width, ^expected_height, _variant} =
             ExImageInfo.info(payload)
  end

  defp decode_data_url("data:" <> rest) do
    assert [mime_type, data] = String.split(rest, ";base64,", parts: 2)
    {mime_type, Base.decode64!(data)}
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

  defp oversized_bmp_header_payload do
    width = 3_000
    height = 1_500
    row_size = div(width * 3 + 3, 4) * 4
    image_size = row_size * height
    file_size = 54 + image_size

    <<"BM", file_size::little-32, 0::little-16, 0::little-16, 54::little-32, 40::little-32,
      width::little-signed-32, height::little-signed-32, 1::little-16, 24::little-16,
      0::little-32, image_size::little-32, 2_835::little-signed-32, 2_835::little-signed-32,
      0::little-32, 0::little-32>>
  end
end
