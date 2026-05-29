defmodule IntellectualClubWeb.Bff.ChatToolResultPreviewTest do
  @moduledoc """
  Tool-result preview and full-text endpoint tests for the SPA BFF.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.Threads

  test "state truncates tool_result text, strips bulky opaque payloads, and full endpoint returns complete text",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Tool result preview", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

    {:ok, assistant_message} =
      Threads.add_message(chat, :assistant, "Answer",
        actor: actor,
        parent_id: user_message.id
      )

    assistant_with_steps =
      Ash.get!(ChatMessage, assistant_message.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    step = List.first(assistant_with_steps.steps || [])
    assert is_map(step)

    tool_call_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 99, type: :tool_call},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: 100,
          type: :tool_result,
          tool_call_item_id: tool_call_item.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    long_text =
      [
        "line 1 - " <> String.duplicate("A", 160),
        "line 2 - " <> String.duplicate("B", 160),
        "line 3 - " <> String.duplicate("C", 160),
        "line 4 - " <> String.duplicate("D", 160),
        "line 5 - " <> String.duplicate("E", 160),
        "line 6 - " <> String.duplicate("F", 160)
      ]
      |> Enum.join("\n")

    content =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: item.id,
          sequence: 1,
          kind: :text,
          content_text: long_text
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat_style_opaque =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: item.id,
          sequence: 2,
          kind: :opaque,
          content_json: %{
            "tool_call_id" => "call_chat",
            "name" => "reader__read_url",
            "raw" => %{"content" => [%{"type" => "text", "text" => long_text}]}
          }
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    responses_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: 101,
          type: :tool_result,
          tool_call_item_id: tool_call_item.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    responses_text_content =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: responses_item.id,
          sequence: 1,
          kind: :text,
          content_text: long_text
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    responses_style_opaque =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: responses_item.id,
          sequence: 2,
          kind: :opaque,
          content_json: %{
            "responses_item" => %{
              "type" => "function_call_output",
              "id" => "fco_123",
              "call_id" => "call_resp",
              "output" => long_text
            },
            "raw" => %{"output" => long_text}
          }
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    reasoning_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 102, type: :reasoning},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _reasoning_text =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: reasoning_item.id,
          sequence: 1,
          kind: :text,
          content_text: "Reasoning summary"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    reasoning_opaque =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: reasoning_item.id,
          sequence: 2,
          kind: :opaque,
          content_json: %{
            "type" => "reasoning",
            "id" => "rs_123",
            "encrypted_content" => String.duplicate("opaque", 200)
          }
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    working =
      conn
      |> get(~p"/api/bff/chat-messages/#{assistant_message.id}/working")
      |> json_response(200)

    step_payload = working["step"] || %{}
    step_payloads = [step_payload]

    preview_content =
      step_payloads
      |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
      |> Enum.filter(fn i -> Map.get(i, "type") == "tool_result" end)
      |> Enum.flat_map(fn i -> Map.get(i, "contents", []) end)
      |> Enum.find(fn c -> Map.get(c, "id") == content.id end)

    chat_style_preview =
      step_payloads
      |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
      |> Enum.filter(fn i -> Map.get(i, "type") == "tool_result" end)
      |> Enum.flat_map(fn i -> Map.get(i, "contents", []) end)
      |> Enum.find(fn c -> Map.get(c, "id") == chat_style_opaque.id end)

    responses_text_preview =
      step_payloads
      |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
      |> Enum.filter(fn i -> Map.get(i, "type") == "tool_result" end)
      |> Enum.flat_map(fn i -> Map.get(i, "contents", []) end)
      |> Enum.find(fn c -> Map.get(c, "id") == responses_text_content.id end)

    responses_style_preview =
      step_payloads
      |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
      |> Enum.filter(fn i -> Map.get(i, "type") == "tool_result" end)
      |> Enum.flat_map(fn i -> Map.get(i, "contents", []) end)
      |> Enum.find(fn c -> Map.get(c, "id") == responses_style_opaque.id end)

    reasoning_contents =
      step_payloads
      |> Enum.flat_map(fn s -> Map.get(s, "items", []) end)
      |> Enum.find(fn i -> Map.get(i, "id") == reasoning_item.id end)
      |> then(&(&1 || %{}))
      |> Map.get("contents", [])

    assert is_map(preview_content)
    assert preview_content["content_text_truncated"] == true
    assert is_binary(preview_content["content_text"])
    assert String.length(preview_content["content_text"]) < String.length(long_text)

    assert is_map(chat_style_preview)

    assert chat_style_preview["content_json"] == %{
             "tool_call_id" => "call_chat",
             "name" => "reader__read_url"
           }

    assert is_map(responses_text_preview)
    assert responses_text_preview["content_text_truncated"] == true
    assert is_binary(responses_text_preview["content_text"])
    assert String.length(responses_text_preview["content_text"]) < String.length(long_text)

    assert is_map(responses_style_preview)

    assert responses_style_preview["content_json"] == %{
             "responses_item" => %{
               "type" => "function_call_output",
               "id" => "fco_123",
               "call_id" => "call_resp"
             }
           }

    assert Enum.all?(reasoning_contents, fn content -> content["kind"] != "opaque" end)
    refute Enum.any?(reasoning_contents, fn content -> content["id"] == reasoning_opaque.id end)

    full =
      conn
      |> get(~p"/api/bff/chat-messages/#{assistant_message.id}/contents/#{content.id}/full")
      |> json_response(200)

    assert get_in(full, ["content", "content_text"]) == long_text
  end
end
