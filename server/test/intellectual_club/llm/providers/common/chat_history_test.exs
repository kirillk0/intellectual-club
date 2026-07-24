defmodule IntellectualClub.Llm.Providers.Common.ChatHistoryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Files
  alias IntellectualClub.Llm.Providers.Common.ChatHistory

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
      ChatHistory.build_messages(history, supports_image_input: false)

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

  test "chat history closes parallel tool calls before one combined media message" do
    assert {:ok, first_file} =
             Files.create_from_upload(%{
               filename: "first.png",
               mime_type: "image/png",
               payload: image_payload()
             })

    assert {:ok, second_file} =
             Files.create_from_upload(%{
               filename: "second.png",
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
              tool_call_item(101, 1, "read_image_1", "read_image"),
              tool_call_item(102, 2, "shell_2", "run_command"),
              tool_call_item(103, 3, "read_image_3", "read_image"),
              tool_result_item(201, 1_001, 101, "read_image_1", "first", first_file),
              tool_result_item(202, 1_002, 102, "shell_2", "shell", nil),
              tool_result_item(203, 1_003, 103, "read_image_3", "second", second_file)
            ]
          }
        ]
      }
    ]

    messages = ChatHistory.build_messages(history, supports_image_input: false)

    assert Enum.map(messages, & &1["role"]) == ["assistant", "tool", "tool", "tool", "user"]

    assert Enum.map(Enum.slice(messages, 1, 3), & &1["tool_call_id"]) == [
             "read_image_1",
             "shell_2",
             "read_image_3"
           ]

    media_content = List.last(messages)["content"]
    assert String.contains?(media_content, "first.png")
    assert String.contains?(media_content, "second.png")
  end

  defp tool_call_item(id, sequence, call_id, name) do
    %{
      id: id,
      sequence: sequence,
      type: :tool_call,
      contents: [
        %{
          sequence: 1,
          kind: :opaque,
          content_json: %{
            "tool_call_id" => call_id,
            "name" => name,
            "raw" => %{
              "id" => call_id,
              "type" => "function",
              "function" => %{"name" => name, "arguments" => "{}"}
            }
          }
        }
      ]
    }
  end

  defp tool_result_item(id, sequence, tool_call_item_id, call_id, text, file) do
    media_contents =
      if file do
        [
          %{
            sequence: 2,
            kind: :media,
            external_id: Ash.UUID.generate(),
            file_id: file.id,
            file: file
          }
        ]
      else
        []
      end

    %{
      id: id,
      sequence: sequence,
      type: :tool_result,
      tool_call_item_id: tool_call_item_id,
      contents: [
        %{sequence: 1, kind: :text, content_text: text},
        %{
          sequence: 10_000,
          kind: :opaque,
          content_json: %{"tool_call_id" => call_id}
        }
        | media_contents
      ]
    }
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
