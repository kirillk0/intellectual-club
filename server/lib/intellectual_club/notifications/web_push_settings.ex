defmodule IntellectualClub.Notifications.WebPushSettings do
  @moduledoc """
  Global Web Push configuration and VAPID key storage.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Notifications,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table("web_push_settings")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("web_push_settings")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :singleton_key, :string do
      allow_nil?(false)
      default("default")
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :public_origin, :string do
      allow_nil?(true)
      public?(true)
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :vapid_subject, :string do
      allow_nil?(true)
      public?(true)
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :vapid_public_key, :string do
      allow_nil?(false)
      public?(true)
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :vapid_private_key, :string do
      allow_nil?(false)
      sensitive?(true)
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :key_revision, :integer do
      allow_nil?(false)
      public?(true)
      default(1)
      constraints(min: 1)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_singleton_key, [:singleton_key])
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :singleton_key,
        :enabled,
        :public_origin,
        :vapid_subject,
        :vapid_public_key,
        :vapid_private_key,
        :key_revision
      ])
    end

    update :update_settings do
      accept([:enabled, :public_origin, :vapid_subject])
      require_atomic?(false)
    end

    update :regenerate_keys do
      accept([:vapid_public_key, :vapid_private_key, :key_revision])
      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:is_admin, true)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:is_admin, true)
    end
  end
end
