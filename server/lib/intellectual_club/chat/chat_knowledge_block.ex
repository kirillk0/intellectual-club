defmodule IntellectualClub.Chat.ChatKnowledgeBlock do
  @moduledoc """
  Binds a knowledge block to a chat with ordering and enable flags.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  sqlite do
    table("chat_knowledge_blocks")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chat_knowledge_blocks")
    repo(IntellectualClub.PostgresRepo)
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
      attribute_type: :integer

    belongs_to :knowledge_block, IntellectualClub.Knowledge.KnowledgeBlock,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_pair, [:chat_id, :knowledge_block_id])
  end

  json_api do
    type "chat-knowledge-blocks"
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:chat_id, :knowledge_block_id, :enabled, :sequence])
      change(relate_actor(:owner))

      change(
        {RequireRelatedAccessByActor,
         relationships: [:chat, :knowledge_block],
         access: [chat: :writable, knowledge_block: :readable]}
      )
    end

    update :update do
      accept([:enabled, :sequence])
      require_atomic?(false)
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
