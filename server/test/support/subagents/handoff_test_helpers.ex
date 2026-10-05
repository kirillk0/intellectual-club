defmodule IntellectualClub.HandoffTestHelpers do
  @moduledoc """
  Helpers for handoff tests: reading the rendered first message of a handoff
  chat, the continuation navigation of chat payloads, and scripting the summary provider (an OpenRouter-compatible chat
  completions endpoint served by `IntellectualClub.TestHttpServer`).
  """

  alias IntellectualClub.Chat.{ChatMessage, Previews}
  alias IntellectualClub.Generation.History

  @doc """
  Creates an OpenRouter chat completions configuration pointing to `base_url`
  (no context length limit, 5 s timeout).
  """
  def create_summary_configuration!(actor, base_url) do
    IntellectualClub.LlmFixtures.create_configuration!(actor,
      provider_attrs: %{
        name: "Handoff summary provider",
        type: :openrouter_chat_completion,
        base_url: base_url
      },
      model_name: "test-model",
      note: nil,
      timeout_seconds: 5,
      context_length: nil
    )
  end

  @doc """
  A scripted streaming chat completion response with one assistant `message`
  (a map, or the answer text).
  """
  def chat_completion_response(message, finish_reason \\ "stop")

  def chat_completion_response(text, finish_reason) when is_binary(text) do
    chat_completion_response(%{"role" => "assistant", "content" => text}, finish_reason)
  end

  def chat_completion_response(%{} = message, finish_reason) do
    {200,
     IntellectualClub.TestHttpServer.sse_chunks([
       %{
         "id" => "chatcmpl-#{System.unique_integer([:positive])}",
         "object" => "chat.completion",
         "created" => 1,
         "model" => "test-chat-model",
         "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]
       }
     ])}
  end

  @doc """
  Text of a message as the model sees it: rendered handoff input for handoff
  messages, the preview text otherwise (message loaded with `steps: [items: [:contents]]`).
  """
  def message_text(%ChatMessage{} = message) do
    if Enum.any?(message_item_types(message), &(&1 in [:handoff_history, :handoff_message])) do
      History.project_user_input_text(message)
    else
      Previews.message_preview_text(message)
    end
  end

  @doc "Concatenates the stored text contents of a message in step/item/content order."
  def stored_message_text(%ChatMessage{} = message) do
    message
    |> ordered_items()
    |> Enum.flat_map(&sorted(&1.contents))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join("\n", &(&1.content_text || ""))
  end

  @doc "Returns the text contents of the items of `item_type` in order."
  def text_contents_for_item_type(%ChatMessage{} = message, item_type) do
    message
    |> ordered_items()
    |> Enum.filter(&(&1.type == item_type))
    |> Enum.flat_map(&sorted(&1.contents))
    |> Enum.filter(&(&1.kind == :text))
  end

  @doc "Returns the item types of a message in step/item order."
  def message_item_types(%ChatMessage{} = message) do
    message |> ordered_items() |> Enum.map(& &1.type)
  end

  @doc "Returns the text contents of all tool results of a message."
  def tool_result_texts(%ChatMessage{} = message) do
    message
    |> ordered_items()
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&sorted(&1.contents))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map(&(&1.content_text || ""))
  end

  @doc "Returns the function names of the `\"tools\"` of a chat completions request."
  def request_tool_names(request) when is_map(request) do
    request
    |> Map.get("tools", [])
    |> List.wrap()
    |> Enum.map(&get_in(&1, ["function", "name"]))
    |> Enum.filter(&is_binary/1)
  end

  @doc "Labels of the continuation navigation of a chat payload (`[]` when absent)."
  def nav_labels(%{"continuation_nav" => nav}) when is_list(nav), do: Enum.map(nav, & &1["label"])
  def nav_labels(_payload), do: []

  @doc "Chat ids of the continuation navigation of a chat payload (`[]` when absent)."
  def nav_chat_ids(%{"continuation_nav" => nav}) when is_list(nav),
    do: Enum.map(nav, & &1["chat_id"])

  def nav_chat_ids(_payload), do: []

  defp ordered_items(message) do
    message.steps |> sorted() |> Enum.flat_map(&sorted(&1.items))
  end

  defp sorted(records), do: records |> List.wrap() |> Enum.sort_by(&(&1.sequence || 0))
end
