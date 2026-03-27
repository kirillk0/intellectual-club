defmodule IntellectualClubWeb.Bff.SerializerTest do
  @moduledoc """
  Unit tests for BFF serializer ordering guarantees.
  """

  use ExUnit.Case, async: true

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClubWeb.Bff.Serializer

  test "branch_message sorts nested steps, items, and contents by sequence" do
    message =
      %ChatMessage{
        id: 11,
        role: :assistant,
        status: :done,
        steps: [
          %ChatMessageStep{
            id: 102,
            sequence: 2,
            status: :done,
            items: [
              %ChatMessageItem{
                id: 202,
                sequence: 2,
                type: :answer,
                contents: [
                  %ChatMessageContent{id: 302, sequence: 2, kind: :text, content_text: "beta"},
                  %ChatMessageContent{id: 301, sequence: 1, kind: :text, content_text: "alpha"}
                ]
              },
              %ChatMessageItem{
                id: 201,
                sequence: 1,
                type: :answer,
                contents: [
                  %ChatMessageContent{id: 303, sequence: 1, kind: :text, content_text: "first"}
                ]
              }
            ]
          },
          %ChatMessageStep{
            id: 101,
            sequence: 1,
            status: :done,
            items: [
              %ChatMessageItem{
                id: 203,
                sequence: 1,
                type: :answer,
                contents: [
                  %ChatMessageContent{id: 304, sequence: 1, kind: :text, content_text: "root"}
                ]
              }
            ]
          }
        ]
      }

    serialized = Serializer.branch_message(message)

    assert Enum.map(serialized.steps, & &1.sequence) == [1, 2]

    [step_one, step_two] = serialized.steps
    assert Enum.map(step_one.items, & &1.sequence) == [1]
    assert Enum.map(step_two.items, & &1.sequence) == [1, 2]

    [first_item, second_item] = step_two.items
    assert Enum.map(first_item.contents, & &1.sequence) == [1]
    assert Enum.map(second_item.contents, & &1.sequence) == [1, 2]
    assert Enum.map(second_item.contents, & &1.content_text) == ["alpha", "beta"]
  end
end
