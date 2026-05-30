defmodule IntellectualClub.Llm.Providers.Common.RoleAlterationFixTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.Common.RoleAlterationFix

  test "inserts empty user around assistant-only chat history after leading system messages" do
    assert RoleAlterationFix.fix_chat_messages([
             %{"role" => "system", "content" => "System"},
             %{"role" => "assistant", "content" => "Hello"}
           ]) == [
             %{"role" => "system", "content" => "System"},
             %{"role" => "user", "content" => ""},
             %{"role" => "assistant", "content" => "Hello"},
             %{"role" => "user", "content" => ""}
           ]
  end

  test "inserts empty user when chat history has only leading system messages" do
    assert RoleAlterationFix.fix_chat_messages([
             %{"role" => "system", "content" => "System"}
           ]) == [
             %{"role" => "system", "content" => "System"},
             %{"role" => "user", "content" => ""}
           ]
  end

  test "merges adjacent chat messages with the same user role" do
    assert RoleAlterationFix.fix_chat_messages([
             %{"role" => "user", "content" => "First"},
             %{"role" => "user", "content" => "Second"}
           ]) == [
             %{"role" => "user", "content" => "First\n\nSecond"}
           ]
  end

  test "preserves rich chat content and inserts a separator block" do
    assert RoleAlterationFix.fix_chat_messages([
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "First"}]},
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "image_url", "image_url" => %{"url" => "file://image.png"}}
               ]
             }
           ]) == [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "First"},
                 %{"type" => "text", "text" => "\n\n"},
                 %{"type" => "image_url", "image_url" => %{"url" => "file://image.png"}}
               ]
             }
           ]
  end

  test "does not merge chat tool messages while still fixing first and last user turns" do
    assert RoleAlterationFix.fix_chat_messages([
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "tool output"}
           ]) == [
             %{"role" => "user", "content" => ""},
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "tool output"},
             %{"role" => "user", "content" => ""}
           ]
  end

  test "does not merge responses non-message items while fixing first and last user turns" do
    function_call = %{
      "type" => "function_call",
      "id" => "fc_1",
      "call_id" => "call_1",
      "name" => "weather__get",
      "arguments" => "{}"
    }

    assert RoleAlterationFix.fix_responses_input_items([function_call]) == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => ""}]
             },
             function_call,
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => ""}]
             }
           ]
  end
end
