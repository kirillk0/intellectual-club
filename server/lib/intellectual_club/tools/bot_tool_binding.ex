defmodule IntellectualClub.Tools.BotToolBinding do
  @moduledoc """
  A bot-level binding of a tool instance.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Tools,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  sqlite do
    table("bot_tool_bindings")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("bot_tool_bindings")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :sharing_mode, :atom do
      allow_nil?(false)
      public?(true)
      default(:shared)
      constraints(one_of: [:shared, :per_user])
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
    identity(:unique_bot_tool_instance, [:bot_id, :tool_instance_id])
  end

  calculations do
    calculate :alias, :string, expr(tool_instance.alias) do
      public?(true)
    end
  end

  json_api do
    type "bot-tool-bindings"
    includes([:bot, :tool_instance])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:bot_id, :tool_instance_id, :sharing_mode, :enabled, :sequence])

      argument :alias, :string do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))

      change(
        {RequireRelatedAccessByActor,
         relationships: [:bot, :tool_instance], access: [bot: :writable, tool_instance: :writable]}
      )
    end

    update :update do
      accept([:tool_instance_id, :sharing_mode, :enabled, :sequence])
      require_atomic?(false)

      argument :alias, :string do
        allow_nil?(true)
        public?(true)
      end

      change(
        {RequireRelatedAccessByActor,
         relationships: [:tool_instance], access: [tool_instance: :writable], required?: false}
      )
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

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
