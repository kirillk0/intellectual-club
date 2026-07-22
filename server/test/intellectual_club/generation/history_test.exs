defmodule IntellectualClub.Generation.HistoryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.History

  @missing_user_message_placeholder "<There is no user message yet, you should write first>"

  test "fixes canonical user boundaries without merging adjacent messages" do
    first = %{role: :assistant, content: "First"}
    second = %{role: :assistant, content: "Second"}

    assert History.fix_role_alteration([first, second]) == [
             %{role: :user, content: @missing_user_message_placeholder},
             first,
             second,
             %{role: :user, content: @missing_user_message_placeholder}
           ]
  end

  test "keeps adjacent canonical user messages separate" do
    history = [
      %{role: :user, content: "First"},
      %{role: :user, content: "Second"}
    ]

    assert History.fix_role_alteration(history) == history
  end

  test "replaces empty legacy and trace user messages" do
    empty_trace_message = %{
      role: :user,
      steps: [
        %{
          sequence: 1,
          items: [
            %{
              sequence: 1,
              type: :input,
              contents: [
                %{sequence: 1, kind: :text, content_text: " \n\t "}
              ]
            }
          ]
        }
      ]
    }

    assert History.fix_role_alteration([
             %{role: :user, content: "  "},
             %{role: :assistant, content: "Answer"},
             empty_trace_message
           ]) == [
             %{role: :user, content: @missing_user_message_placeholder},
             %{role: :assistant, content: "Answer"},
             %{role: :user, content: @missing_user_message_placeholder}
           ]
  end

  test "keeps user messages containing canonical media" do
    media_message = %{
      role: :user,
      steps: [
        %{
          sequence: 1,
          items: [
            %{
              sequence: 1,
              type: :input,
              contents: [%{sequence: 1, kind: :media, external_id: "media-id"}]
            }
          ]
        }
      ]
    }

    assert History.fix_role_alteration([media_message]) == [media_message]
  end

  test "creates one placeholder for empty canonical history" do
    assert History.fix_role_alteration([]) == [
             %{role: :user, content: @missing_user_message_placeholder}
           ]
  end

  test "normalizes legacy messages without provider projection" do
    assert History.normalize_message(%{role: :user, content: "Hello"}) == %{
             "role" => "user",
             "content" => "Hello"
           }

    assert History.normalize_message(%{"role" => "assistant", "content" => [%{"type" => "text"}]}) ==
             %{"role" => "assistant", "content" => [%{"type" => "text"}]}

    assert History.normalize_message(%{role: "user", content: "Wrong boundary"}) == nil
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

  test "trace helpers consume canonical atom-valued domain maps" do
    assert History.item_type(:error) == :error
    assert History.item_type(:other) == :other
    assert History.item_type(%{type: "answer"}) == :other

    assert History.content_kind(:media) == :media
    assert History.content_kind(%{kind: "text"}) == :other

    refute History.trace_message?(%{"steps" => []})
    assert History.message_role(%{"role" => "assistant"}) == nil
  end
end
