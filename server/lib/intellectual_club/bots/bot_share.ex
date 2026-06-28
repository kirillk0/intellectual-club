defmodule IntellectualClub.Bots.BotShare do
  @moduledoc """
  Grants read access to a bot for all members of a user group.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Bots,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Accounts.Changes.RequireActorMembershipInRelatedUserGroup
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor
  alias IntellectualClub.Sharing.Changes.DeleteChatSharesForRevokedShare

  postgres do
    table("bot_shares")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:bot_id], name: "bot_shares_bot_id_index")
      index([:user_group_id], name: "bot_shares_user_group_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :bot, IntellectualClub.Bots.Bot,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :user_group, IntellectualClub.Accounts.UserGroup,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_pair, [:bot_id, :user_group_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:bot_id, :user_group_id])
      change({RequireRelatedAccessByActor, relationships: [:bot], access: :writable})
      change({RequireActorMembershipInRelatedUserGroup, relationship: :user_group})
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteChatSharesForRevokedShare, resource: :bot})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(bot.owner_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if expr(bot.owner_id == ^actor(:id))
    end
  end
end
