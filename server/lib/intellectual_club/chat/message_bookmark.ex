defmodule IntellectualClub.Chat.MessageBookmark do
  @moduledoc """
  Stores user bookmarks for chat messages.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  postgres do
    table("message_bookmarks")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:owner_id], name: "message_bookmarks_owner_id_index")
      index([:chat_message_id], name: "message_bookmarks_chat_message_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :chat_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer
  end

  identities do
    identity(:unique_owner_chat_message, [:owner_id, :chat_message_id])
  end

  json_api do
    type "message-bookmarks"
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:chat_message_id])
      change(relate_actor(:owner))

      change({RequireRelatedAccessByActor, relationships: [:chat_message], access: :readable})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
