defmodule IntellectualClub.Bots.BotCompatibleConfigurationTag do
  @moduledoc """
  Join resource for bot-compatible LLM configuration tags.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Bots,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  sqlite do
    table("bot_compatible_configuration_tags")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("bot_compatible_configuration_tags")
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

    belongs_to :bot, IntellectualClub.Bots.Bot,
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
    identity(:unique_pair, [:bot_id, :llm_configuration_tag_id])
  end

  json_api do
    type "bot-compatible-configuration-tags"
    includes([:llm_configuration_tag, :bot])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:bot_id, :llm_configuration_tag_id])
      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:bot, :llm_configuration_tag]})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
      authorize_if expr(exists(bot.shares.user_group.memberships, user_id == ^actor(:id)))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
