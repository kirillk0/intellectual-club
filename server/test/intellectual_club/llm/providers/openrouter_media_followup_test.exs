defmodule IntellectualClub.Llm.Providers.OpenRouterMediaFollowupTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Files
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.Common.RequestBuilder
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion

  test "projects tool-result images when image input is enabled" do
    {:ok, file} = Files.create_from_binary("cat.png", "image/png", png_payload())

    raw_request =
      RequestBuilder.build_chat_completions_payload(
        "moonshotai/kimi-k3",
        %{},
        [%{"role" => "user", "content" => "Inspect the image."}],
        tools: []
      )

    runtime_step =
      RuntimeTrace.new_step(
        raw_request: raw_request,
        raw_response: %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => ""}}
          ]
        }
      )

    media = %{
      kind: :media,
      sequence: 2,
      external_id: Ash.UUID.generate(),
      file_id: file.id,
      file: %{
        id: file.id,
        external_id: file.external_id,
        filename: file.filename,
        mime_type: file.mime_type,
        size_bytes: file.size_bytes,
        sha256: file.sha256
      }
    }

    followup =
      OpenRouterChatCompletion.build_followup_request(%{
        context: %{
          cache_control_enabled: false,
          chat_id: 131,
          model_name: "moonshotai/kimi-k3",
          parameters: %{},
          supports_image_input: true
        },
        runtime_step: runtime_step,
        results: [tool_result(media)],
        tools: []
      })

    [_initial_user, _assistant, tool_message, media_message] =
      followup.raw_request["messages"]

    assert tool_message["role"] == "tool"
    assert media_message["role"] == "user"

    assert [placeholder, image] = media_message["content"]
    assert placeholder["type"] == "text"
    assert String.contains?(placeholder["text"], to_string(file.external_id))
    assert image["type"] == "image_url"

    assert get_in(image, [
             "image_url",
             "url",
             "$intellectual_club_file",
             "source_file_external_id"
           ]) == to_string(file.external_id)
  end

  defp tool_result(media) do
    %{
      call_id: "read_image_1",
      name: "read_image",
      args: %{},
      raw: %{
        "id" => "read_image_1",
        "type" => "function",
        "function" => %{"name" => "read_image", "arguments" => "{}"}
      },
      text: "done",
      result_raw: %{"ok" => true},
      media_contents: [media],
      artifact_contents: []
    }
  end

  defp png_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
