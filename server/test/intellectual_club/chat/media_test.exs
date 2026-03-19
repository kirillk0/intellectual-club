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

    assert String.contains?(placeholder, "content_id=")
    assert String.starts_with?(data_url, "data:image/png;base64,")
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

    assert String.contains?(placeholder, "content_id=")
    assert String.starts_with?(data_url, "data:image/png;base64,")
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

  defp image_content!(payload, mime_type) do
    assert {:ok, file} =
             Files.create_from_upload(%{
               filename: "attached.png",
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

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
