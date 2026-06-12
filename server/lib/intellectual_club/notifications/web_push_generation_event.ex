defmodule IntellectualClub.Notifications.WebPushGenerationEvent do
  @moduledoc """
  Idempotency ledger for generation completion Web Push notifications.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Notifications,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table("web_push_generation_events")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("web_push_generation_events")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:done, :error])
    end

    attribute :suppressed, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :delivered_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
      constraints(min: 0)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :chat_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_message_status, [:chat_message_id, :status])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:chat_message_id, :status, :suppressed, :delivered_count])
      change(relate_actor(:owner))
    end

    update :mark_delivered do
      accept([:delivered_count])
      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
      authorize_if actor_attribute_equals(:is_admin, true)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:update) do
      authorize_if actor_present()
    end
  end
end
