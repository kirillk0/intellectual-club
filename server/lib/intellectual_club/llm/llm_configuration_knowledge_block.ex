defmodule IntellectualClub.Llm.LlmConfigurationKnowledgeBlock do
  @moduledoc """
  Binds a knowledge block to an LLM configuration.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Llm,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  sqlite do
    table("llm_configuration_knowledge_blocks")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("llm_configuration_knowledge_blocks")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :selection, :atom do
      allow_nil?(false)
      public?(true)
      default(:bottom)
      constraints(one_of: [:top, :bottom])
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
    end

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer

    belongs_to :knowledge_block, IntellectualClub.Knowledge.KnowledgeBlock,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer
  end

  identities do
    identity(:unique_pair, [:llm_configuration_id, :knowledge_block_id])
  end

  json_api do
    type "llm-configuration-knowledge-blocks"
    includes([:llm_configuration, :knowledge_block])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:llm_configuration_id, :knowledge_block_id, :selection, :enabled, :sequence])
      change(relate_actor(:owner))

      change(
        {RequireRelatedAccessByActor,
         relationships: [:llm_configuration, :knowledge_block],
         access: [llm_configuration: :writable, knowledge_block: :readable]}
      )
    end

    update :update do
      accept([:selection, :enabled, :sequence])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     exists(
                       llm_configuration.shares.user_group.memberships,
                       user_id == ^actor(:id)
                     )
                   )
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
