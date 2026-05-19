defmodule IntellectualClub.Chat do
  @moduledoc """
  Chat domain (Ash).

  For the prototype we keep the domain minimal: chats and chat messages only.
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(IntellectualClub.Chat.Chat)
    resource(IntellectualClub.Chat.ChatShare)
    resource(IntellectualClub.Chat.ChatUploadSession)
    resource(IntellectualClub.Chat.ChatMessage)
    resource(IntellectualClub.Chat.MessageBookmark)
    resource(IntellectualClub.Chat.ChatKnowledgeBlock)
    resource(IntellectualClub.Chat.ChatMessageStep)
    resource(IntellectualClub.Chat.ChatMessageItem)
    resource(IntellectualClub.Chat.ChatMessageContent)
  end

  json_api do
    routes do
      base_route "/chats", IntellectualClub.Chat.Chat do
        index :read
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end

      base_route "/chat-messages", IntellectualClub.Chat.ChatMessage do
        index :read
        get(:read)
        delete(:destroy)
      end

      base_route "/chat-knowledge-blocks", IntellectualClub.Chat.ChatKnowledgeBlock do
        index :read
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end

      base_route "/chat-message-steps", IntellectualClub.Chat.ChatMessageStep do
        index :read
        get(:read)
      end

      base_route "/chat-message-items", IntellectualClub.Chat.ChatMessageItem do
        index :read
        get(:read)
      end

      base_route "/chat-message-contents", IntellectualClub.Chat.ChatMessageContent do
        index :read
        get(:read)
      end
    end
  end
end
