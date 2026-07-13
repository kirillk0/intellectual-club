defmodule IntellectualClub.Chat.PreviewsTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Previews

  test "builds previews from atom-valued Ash trace fields" do
    message =
      message(:user, [
        content(2, :media, ""),
        content(1, :text, "First\nline")
      ])

    assert Previews.message_preview_text(message) == "First\nline"
    assert Previews.message_preview(message, 20) == {"First line", "user"}
  end

  test "does not interpret decoded string-valued maps as domain messages" do
    decoded_message = %{
      role: "user",
      steps: [
        %{
          sequence: 1,
          items: [
            %{
              sequence: 1,
              type: "input",
              contents: [%{sequence: 1, kind: "text", content_text: "Wrong boundary"}]
            }
          ]
        }
      ]
    }

    assert_raise FunctionClauseError, fn ->
      apply(Previews, :message_preview_text, [decoded_message])
    end
  end

  defp message(role, contents) do
    %ChatMessage{
      role: role,
      steps: [
        %ChatMessageStep{
          sequence: 1,
          items: [
            %ChatMessageItem{
              sequence: 1,
              type: :input,
              contents: contents
            }
          ]
        }
      ]
    }
  end

  defp content(sequence, kind, text) do
    %ChatMessageContent{sequence: sequence, kind: kind, content_text: text}
  end
end
