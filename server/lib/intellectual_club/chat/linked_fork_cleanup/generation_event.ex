defmodule IntellectualClub.Chat.LinkedForkCleanup.GenerationEvent do
  @moduledoc """
  Private deletion-only projection of the Web Push idempotency ledger.

  The public ledger intentionally has no destroy action. Deleting a message must
  remove its dependent delivery keys, but only the message owner may do so. This
  projection does not manage the existing table's schema or expose public routes.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat.LinkedForkCleanup,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("web_push_generation_events")
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
