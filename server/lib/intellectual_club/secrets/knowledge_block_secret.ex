defmodule IntellectualClub.Secrets.KnowledgeBlockSecret do
  @moduledoc """
  A managed-secret attachment owned by one knowledge block.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Secrets,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor
  alias IntellectualClub.Secrets.Changes.DeleteAssociatedSecret
  alias IntellectualClub.Secrets.Validations.RequireUnboundSecret

  postgres do
    table("knowledge_block_secrets")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:knowledge_block_id], name: "knowledge_block_secrets_block_id_index")
      index([:secret_id], name: "knowledge_block_secrets_secret_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :external_id, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :env_name, :string do
      allow_nil?(false)
      public?(true)
      constraints(trim?: true, allow_empty?: false, match: ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    end

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
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
      attribute_type: :integer

    belongs_to :secret, IntellectualClub.Secrets.Secret,
      allow_nil?: false,
      attribute_type: :integer,
      public?: true
  end

  identities do
    identity(:unique_external_id, [:external_id])
    identity(:unique_secret, [:secret_id])
    identity(:unique_block_env_name, [:knowledge_block_id, :env_name])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:knowledge_block_id, :secret_id, :env_name, :sequence, :enabled])
      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:knowledge_block, :secret]})
      validate({RequireUnboundSecret, []})
    end

    update :update do
      primary?(true)
      accept([:env_name, :sequence, :enabled])
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteAssociatedSecret, field: :secret_id, strict?: true})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
      authorize_if expr(enabled == true and knowledge_block.owner_id == ^actor(:id))

      authorize_if expr(
                     enabled == true and
                       exists(
                         knowledge_block.shares.user_group.memberships,
                         user_id == ^actor(:id)
                       )
                   )

      authorize_if expr(
                     enabled == true and
                       exists(
                         knowledge_block.bot_bindings,
                         enabled == true and
                           exists(bot.shares.user_group.memberships, user_id == ^actor(:id))
                       )
                   )

      authorize_if expr(
                     enabled == true and
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

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
