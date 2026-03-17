defmodule IntellectualClub.Generation.SystemPromptTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.SystemPrompt

  test "removes knowledge block comment lines before rendering prompt variables" do
    prompt =
      SystemPrompt.build(
        bot_blocks: [
          %{
            name: "Commented block",
            content: "{{dynamic_line}}\n//// remove this line\nVisible {{name}}",
            variables: %{}
          }
        ],
        bot_variables: %{
          "dynamic_line" => "//// keep this rendered line",
          "name" => "Alice"
        }
      )

    assert String.contains?(prompt, "//// keep this rendered line")
    assert String.contains?(prompt, "Visible Alice")
    refute String.contains?(prompt, "remove this line")
  end
end
