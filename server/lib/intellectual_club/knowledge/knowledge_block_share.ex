defmodule IntellectualClub.Knowledge.KnowledgeBlockShare do
  @moduledoc """
  Grants direct read access to a knowledge block for all members of a user group.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Knowledge,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Accounts.Changes.RequireActorMembershipInRelatedUserGroup
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  postgres do
    table("knowledge_block_shares")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:knowledge_block_id], name: "knowledge_block_shares_knowledge_block_id_index")
      index([:user_group_id], name: "knowledge_block_shares_user_group_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :knowledge_block, IntellectualClub.Knowledge.KnowledgeBlock,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :user_group, IntellectualClub.Accounts.UserGroup,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_pair, [:knowledge_block_id, :user_group_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:knowledge_block_id, :user_group_id])

      change({RequireRelatedAccessByActor, relationships: [:knowledge_block], access: :writable})

      change({RequireActorMembershipInRelatedUserGroup, relationship: :user_group})
    end

    destroy :destroy do
      primary?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(knowledge_block.owner_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if expr(knowledge_block.owner_id == ^actor(:id))
    end
  end
end
