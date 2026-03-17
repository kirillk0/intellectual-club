defmodule IntellectualClub.Llm.LlmConfigurationTagBinding do
  @moduledoc """
  Join resource for binding flat tags to LLM configurations.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Llm,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  sqlite do
    table("llm_configuration_tag_bindings")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("llm_configuration_tag_bindings")
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

    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer

    belongs_to :llm_configuration_tag, IntellectualClub.Llm.LlmConfigurationTag,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer
  end

  calculations do
    calculate :tag_name, :string, {IntellectualClub.Llm.Calculations.ConfigurationTagName, []} do
      public?(true)
    end
  end

  identities do
    identity(:unique_pair, [:llm_configuration_id, :llm_configuration_tag_id])
  end

  json_api do
    type "llm-configuration-tag-bindings"
    includes([:llm_configuration_tag, :llm_configuration])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:llm_configuration_id, :llm_configuration_tag_id])
      change(relate_actor(:owner))

      change(
        {RequireRelatedOwnedByActor, relationships: [:llm_configuration, :llm_configuration_tag]}
      )
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

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
