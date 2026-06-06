defmodule IntellectualClub.Llm.Providers.Common.RoleAlterationFixTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.Common.RoleAlterationFix

  @missing_user_message_placeholder "<There is no user message yet, you should write first>"

  test "inserts placeholder user around assistant-only chat history after leading system messages" do
    assert RoleAlterationFix.fix_chat_messages([
             %{"role" => "system", "content" => "System"},
             %{"role" => "assistant", "content" => "Hello"}
           ]) == [
             %{"role" => "system", "content" => "System"},
             %{"role" => "user", "content" => @missing_user_message_placeholder},
             %{"role" => "assistant", "content" => "Hello"},
             %{"role" => "user", "content" => @missing_user_message_placeholder}
           ]
  end

  test "inserts placeholder user when chat history has only leading system messages" do
    assert RoleAlterationFix.fix_chat_messages([
             %{"role" => "system", "content" => "System"}
           ]) == [
             %{"role" => "system", "content" => "System"},
             %{"role" => "user", "content" => @missing_user_message_placeholder}
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
             %{"role" => "user", "content" => @missing_user_message_placeholder},
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "tool output"},
             %{"role" => "user", "content" => @missing_user_message_placeholder}
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
               "content" => [
                 %{"type" => "input_text", "text" => @missing_user_message_placeholder}
               ]
             },
             function_call,
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => @missing_user_message_placeholder}
               ]
             }
           ]
  end
end
