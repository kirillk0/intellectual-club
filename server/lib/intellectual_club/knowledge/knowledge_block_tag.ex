defmodule IntellectualClub.Knowledge.KnowledgeBlockTag do
  @moduledoc """
  Join resource for the many-to-many relationship between blocks and tags.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Knowledge,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  sqlite do
    table("knowledge_block_tags")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("knowledge_block_tags")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)
    create_timestamp(:created_at, public?: true)
    update_timestamp(:updated_at, public?: true)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :knowledge_block, IntellectualClub.Knowledge.KnowledgeBlock,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer

    belongs_to :knowledge_tag, IntellectualClub.Knowledge.KnowledgeTag,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer
  end

  identities do
    identity(:unique_pair, [:knowledge_block_id, :knowledge_tag_id])
  end

  json_api do
    type "knowledge-block-tags"
    includes([:knowledge_tag, :knowledge_block])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:knowledge_block_id, :knowledge_tag_id])
      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:knowledge_block, :knowledge_tag]})
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
