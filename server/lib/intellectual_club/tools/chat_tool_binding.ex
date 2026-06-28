defmodule IntellectualClub.Tools.ChatToolBinding do
  @moduledoc """
  A chat-level binding of a tool instance.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Tools,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  postgres do
    table("chat_tool_bindings")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:owner_id], name: "chat_tool_bindings_owner_id_index")
      index([:chat_id, :enabled], name: "chat_tool_bindings_chat_enabled_index")
    end
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

    belongs_to :chat, IntellectualClub.Chat.Chat,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer

    belongs_to :tool_instance, IntellectualClub.Tools.ToolInstance,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer
  end

  identities do
    identity(:unique_chat_tool_instance, [:chat_id, :tool_instance_id])
  end

  calculations do
    calculate :alias, :string, expr(tool_instance.alias) do
      public?(true)
    end
  end

  json_api do
    type "chat-tool-bindings"
    includes([:chat, :tool_instance])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:chat_id, :tool_instance_id, :enabled, :sequence])

      argument :alias, :string do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))

      change(
        {RequireRelatedAccessByActor,
         relationships: [:chat, :tool_instance],
         access: [chat: :writable, tool_instance: :writable]}
      )
    end

    update :update do
      accept([:tool_instance_id, :enabled, :sequence])
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
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
