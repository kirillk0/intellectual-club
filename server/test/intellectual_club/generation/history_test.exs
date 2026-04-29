defmodule IntellectualClub.Generation.HistoryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.History

  test "normalizes legacy messages without provider projection" do
    assert History.normalize_message(%{role: :user, content: "Hello"}) == %{
             "role" => "user",
             "content" => "Hello"
           }

    assert History.normalize_message(%{"role" => "assistant", "content" => [%{"type" => "text"}]}) ==
             %{"role" => "assistant", "content" => [%{"type" => "text"}]}

    assert History.normalize_message(%{role: :system, content: "Ignored"}) == nil
  end

  test "extracts ordered trace text and opaque payloads" do
    message = %{
      role: :assistant,
      steps: [
        %{
          sequence: 2,
          items: [
            %{
              sequence: 1,
              type: :answer,
              contents: [
                %{sequence: 2, kind: :text, content_text: "second"},
                %{sequence: 1, kind: :text, content_text: "first-"}
              ]
            }
          ]
        },
        %{
          sequence: 1,
          items: [
            %{
              sequence: 1,
              type: :tool_call,
              contents: [
                %{sequence: 1, kind: :opaque, content_json: %{"name" => "tool"}}
              ]
            }
          ]
        }
      ]
    }

    assert History.trace_message?(message)
    assert History.message_role(message) == "assistant"
    assert History.project_text_for_item_type(message, :answer) == "first-second"

    [tool_item] =
      message
      |> History.steps()
      |> Enum.sort_by(&History.sort_seq/1)
      |> hd()
      |> History.items()

    assert History.item_type(tool_item) == :tool_call
    assert History.opaque_payloads(tool_item) == [%{"name" => "tool"}]
  end
end
