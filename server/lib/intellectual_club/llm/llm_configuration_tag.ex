defmodule IntellectualClub.Llm.LlmConfigurationTag do
  @moduledoc """
  A flat tag for organizing LLM configurations and bot compatibility rules.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Llm,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  sqlite do
    table("llm_configuration_tags")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("llm_configuration_tags")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    has_many :configuration_bindings, IntellectualClub.Llm.LlmConfigurationTagBinding do
      destination_attribute(:llm_configuration_tag_id)
    end

    has_many :bot_bindings, IntellectualClub.Bots.BotCompatibleConfigurationTag do
      destination_attribute(:llm_configuration_tag_id)
    end
  end

  identities do
    identity(:unique_name, [:owner_id, :name])
  end

  json_api do
    type "llm-configuration-tags"
  end

  actions do
    defaults([:read, :destroy])

    read :search do
      argument :q, :string do
        allow_nil?(true)
        public?(true)
      end

      prepare fn query, _context ->
        maybe_filter_by_query(query)
      end
    end

    create :create do
      accept([:name])
      change(relate_actor(:owner))
    end

    update :update do
      accept([:name])
    end
  end

  defp maybe_filter_by_query(query) do
    q =
      case Ash.Query.get_argument(query, :q) do
        q when is_binary(q) -> String.trim(q)
        _ -> ""
      end

    if q == "" do
      query
    else
      Ash.Query.filter(query, contains(name, ^q))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     exists(
                       configuration_bindings.llm_configuration.shares.user_group.memberships,
                       user_id == ^actor(:id)
                     )
                   )

      authorize_if expr(
                     exists(
                       bot_bindings.bot.shares.user_group.memberships,
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
