defmodule IntellectualClub.Knowledge.KnowledgeBlockFile do
  @moduledoc """
  File attachment binding for a knowledge block.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Knowledge,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Files.Changes.DeleteAssociatedFile
  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  sqlite do
    table("knowledge_block_files")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("knowledge_block_files")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :external_id, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

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

    belongs_to :file, IntellectualClub.Files.File,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer
  end

  identities do
    identity(:unique_external_id, [:external_id])
  end

  json_api do
    type "knowledge-block-files"
    includes([:knowledge_block, :file])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:knowledge_block_id, :file_id, :sequence])
      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:knowledge_block]})
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteAssociatedFile, field: :file_id})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     exists(
                       knowledge_block.bot_bindings,
                       enabled == true and
                         exists(bot.shares.user_group.memberships, user_id == ^actor(:id))
                     )
                   )

      authorize_if expr(
                     exists(
                       knowledge_block.llm_configuration_bindings,
                       enabled == true and
                         exists(
                           llm_configuration.shares.user_group.memberships,
                           user_id == ^actor(:id)
                         )
                     )
                   )
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
