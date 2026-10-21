defmodule IntellectualClub.Chat.GenerationConfiguration do
  @moduledoc """
  Resolves the LLM configuration pinned by a generation.

  The chat configuration selector may change while a generation is running; it
  only applies to the next message. Work derived from a running generation
  (subagent chats, tool handoffs) must keep the configuration that generation
  started with. The resolution mirrors generation retry/recovery: the assistant
  message configuration when it is readable, otherwise the chat configuration.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage

  @spec pinned_id(ChatMessage.t() | integer() | nil, Chat.t(), term()) :: integer() | nil
  def pinned_id(%ChatMessage{chat_id: chat_id} = message, %Chat{id: chat_id} = chat, actor) do
    case Ash.load(message, [:llm_configuration], actor: actor) do
      {:ok, %ChatMessage{llm_configuration: %{id: id}}} when is_integer(id) -> id
      _other -> chat.llm_configuration_id
    end
  end

  def pinned_id(message_id, %Chat{} = chat, actor) when is_integer(message_id) do
    case Ash.get(ChatMessage, message_id, actor: actor) do
      {:ok, %ChatMessage{} = message} -> pinned_id(message, chat, actor)
      _other -> chat.llm_configuration_id
    end
  end

  def pinned_id(_message, %Chat{} = chat, _actor), do: chat.llm_configuration_id
end
