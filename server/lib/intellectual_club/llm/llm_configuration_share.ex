defmodule IntellectualClub.Llm.LlmConfigurationShare do
  @moduledoc """
  Grants read access to an LLM configuration for all members of a user group.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Llm,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Accounts.Changes.RequireActorMembershipInRelatedUserGroup
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor
  alias IntellectualClub.Sharing.Changes.DeleteChatSharesForRevokedShare

  postgres do
    table("llm_configuration_shares")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:llm_configuration_id], name: "llm_configuration_shares_llm_configuration_id_index")
      index([:user_group_id], name: "llm_configuration_shares_user_group_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :user_group, IntellectualClub.Accounts.UserGroup,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_pair, [:llm_configuration_id, :user_group_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:llm_configuration_id, :user_group_id])

      change(
        {RequireRelatedAccessByActor, relationships: [:llm_configuration], access: :writable}
      )

      change({RequireActorMembershipInRelatedUserGroup, relationship: :user_group})
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteChatSharesForRevokedShare, resource: :llm_configuration})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(llm_configuration.owner_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if expr(llm_configuration.owner_id == ^actor(:id))
    end
  end
end
