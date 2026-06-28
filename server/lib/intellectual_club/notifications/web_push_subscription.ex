defmodule IntellectualClub.Notifications.WebPushSubscription do
  @moduledoc """
  Stored browser Push API subscription for one authenticated user.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Notifications,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("web_push_subscriptions")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:owner_id], name: "web_push_subscriptions_owner_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :endpoint, :string do
      allow_nil?(false)
      public?(true)
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :p256dh, :string do
      allow_nil?(false)
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :auth, :string do
      allow_nil?(false)
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :user_agent, :string do
      allow_nil?(true)
      public?(true)
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :key_revision, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :expiration_time, :integer do
      allow_nil?(true)
      constraints(min: 0)
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_endpoint, [:endpoint])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :endpoint,
        :p256dh,
        :auth,
        :user_agent,
        :key_revision,
        :expiration_time,
        :last_seen_at
      ])

      change(relate_actor(:owner))
    end

    update :update do
      accept([:p256dh, :auth, :user_agent, :key_revision, :expiration_time, :last_seen_at])
      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:update) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
