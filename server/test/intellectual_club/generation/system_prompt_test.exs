defmodule IntellectualClub.Generation.SystemPromptTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.SystemPrompt

  test "removes knowledge block comment lines and preserves prompt placeholders" do
    prompt =
      SystemPrompt.build(
        bot_blocks: [
          %{
            name: "Commented block",
            content: "{{dynamic_line}}\n//// remove this line\nVisible {{name}}"
          }
        ]
      )

    assert String.contains?(prompt, "{{dynamic_line}}")
    assert String.contains?(prompt, "Visible {{name}}")
    refute String.contains?(prompt, "remove this line")
  end

  test "appends chat-style file placeholders after rendered knowledge block text" do
    file_external_id = Ash.UUID.generate()
    disabled_file_external_id = Ash.UUID.generate()

    prompt =
      SystemPrompt.build(
        bot_blocks: [
          %{
            name: "Files block",
            content: "//// hidden note\nVisible {{name}}",
            file_bindings: [
              %{
                id: 1,
                external_id: Ash.UUID.generate(),
                sequence: 0,
                file_id: 10,
                file: %{
                  id: 10,
                  external_id: file_external_id,
                  filename: "report.pdf",
                  mime_type: "application/pdf",
                  size_bytes: 42,
                  sha256: String.duplicate("a", 64)
                }
              },
              %{
                id: 2,
                external_id: Ash.UUID.generate(),
                enabled: false,
                sequence: 1,
                file_id: 11,
                file: %{
                  id: 11,
                  external_id: disabled_file_external_id,
                  filename: "disabled.pdf",
                  mime_type: "application/pdf",
                  size_bytes: 84,
                  sha256: String.duplicate("c", 64)
                }
              }
            ]
          }
        ]
      )

    assert prompt =~
             "Visible {{name}}\n[Attached file file_id=#{file_external_id} filename=\"report.pdf\" mime_type=\"application/pdf\" size_bytes=42]"

    refute prompt =~ disabled_file_external_id
    refute prompt =~ "hidden note"
  end

  test "renders attachment-only knowledge blocks as valid prompt sections" do
    file_external_id = Ash.UUID.generate()

    prompt =
      SystemPrompt.build(
        bot_blocks: [
          %{
            name: "",
            content: "//// only a comment",
            file_bindings: [
              %{
                id: 1,
                external_id: Ash.UUID.generate(),
                sequence: 0,
                file_id: 10,
                file: %{
                  id: 10,
                  external_id: file_external_id,
                  filename: "data.csv",
                  mime_type: "text/csv",
                  size_bytes: 12,
                  sha256: String.duplicate("b", 64)
                }
              }
            ]
          }
        ]
      )

    assert prompt ==
             "[Attached file file_id=#{file_external_id} filename=\"data.csv\" mime_type=\"text/csv\" size_bytes=12]\n\n---"
  end
end
