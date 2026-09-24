defmodule IntellectualClub.Chat.LinkedForkCleanup.Bookmark do
  @moduledoc """
  Private cleanup of bookmarks whose target message is being deleted.

  A shared message may be bookmarked by another user. Its owner can remove those
  dangling references without gaining general access to the user's bookmarks.
  The existing bookmark resource remains the normal user-facing API.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat.LinkedForkCleanup,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("message_bookmarks")
    repo(IntellectualClub.Repo)
    migrate?(false)
  end

  attributes do
    integer_primary_key(:id)
  end

  relationships do
    belongs_to :chat_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: false,
      attribute_type: :integer
  end

  actions do
    read :read do
      primary?(true)
      public?(false)
    end

    destroy :destroy do
      primary?(true)
      public?(false)
    end
  end

  policies do
    policy action_type([:read, :destroy]) do
      authorize_if expr(chat_message.owner_id == ^actor(:id))
    end
  end
end
