defmodule IntellectualClub.Accounts.UserGroupMembership do
  @moduledoc """
  Join resource that stores membership of users in administrative groups.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Accounts,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table("user_group_memberships")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("user_group_memberships")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :user_group, IntellectualClub.Accounts.UserGroup,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_pair, [:user_id, :user_group_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:user_id, :user_group_id])
    end

    destroy :destroy do
      primary?(true)
    end
  end

  policies do
    policy action_type([:read, :create, :destroy]) do
      authorize_if actor_attribute_equals(:is_admin, true)
      forbid_if always()
    end
  end
end
