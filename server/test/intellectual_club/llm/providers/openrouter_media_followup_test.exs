defmodule IntellectualClub.Llm.Providers.OpenRouterMediaFollowupTest do
  use IntellectualClub.DataCase, async: true

  alias IntellectualClub.Files
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.Common.RequestBuilder
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion

  test "projects tool-result images when image input is enabled" do
    {:ok, file} = Files.create_from_binary("cat.png", "image/png", png_1x1())

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
end
