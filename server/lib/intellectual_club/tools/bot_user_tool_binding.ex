defmodule IntellectualClub.Tools.BotUserToolBinding do
  @moduledoc """
  A per-user tool binding override for a bot.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Tools,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  postgres do
    table("bot_user_tool_bindings")
    repo(IntellectualClub.Repo)
  end

  attributes do
    integer_primary_key(:id)

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

    belongs_to :bot, IntellectualClub.Bots.Bot,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer

    belongs_to :tool_instance, IntellectualClub.Tools.ToolInstance,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer
  end

  identities do
    identity(:unique_owner_bot_tool_instance, [:owner_id, :bot_id, :tool_instance_id])
  end

  calculations do
    calculate :alias, :string, expr(tool_instance.alias) do
      public?(true)
    end
  end

  json_api do
    type "bot-user-tool-bindings"
    includes([:bot, :tool_instance])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:bot_id, :tool_instance_id, :enabled, :sequence])

      argument :alias, :string do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))

      change(
        {RequireRelatedAccessByActor,
         relationships: [:bot, :tool_instance], access: [bot: :readable, tool_instance: :writable]}
      )
    end

    update :update do
      accept([:enabled, :sequence])
      require_atomic?(false)

      argument :alias, :string do
        allow_nil?(true)
        public?(true)
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
