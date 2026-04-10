defmodule IntellectualClub.Generation.HistoryMediaTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Files
  alias IntellectualClub.Generation.History

  test "chat history includes tool-result media placeholder follow-up and ignores artifacts" do
    assert {:ok, file} =
             Files.create_from_upload(%{
               filename: "result.png",
               mime_type: "image/png",
               payload: image_payload()
             })

    history = [
      %{
        role: :assistant,
        steps: [
          %{
            sequence: 1,
            items: [
              %{
                sequence: 1,
                type: :tool_result,
                contents: [
                  %{sequence: 1, kind: :text, content_text: "tool text"},
                  %{
                    sequence: 10_000,
                    kind: :opaque,
                    content_json: %{"tool_call_id" => "call-123"}
                  },
                  %{
                    sequence: 2,
                    kind: :media,
                    external_id: "content-123",
                    file_id: file.id,
                    file: file
                  }
                ]
              },
              %{
                sequence: 2,
                type: :artifact,
                contents: [
                  %{
                    sequence: 1,
                    kind: :media,
                    external_id: "artifact-123",
                    file_id: file.id,
                    file: file
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    messages =
      History.build_chat_completions_history_messages(history, supports_image_input: false)

    assert Enum.any?(messages, fn message ->
             message["role"] == "tool" and message["content"] == "tool text"
           end)

    assert Enum.any?(messages, fn message ->
             message["role"] == "user" and
               String.contains?(to_string(message["content"]), "[Attached file") and
               String.contains?(to_string(message["content"]), "result.png")
           end)

    refute Enum.any?(messages, fn message ->
             String.contains?(to_string(message["content"]), "artifact-123")
           end)
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
