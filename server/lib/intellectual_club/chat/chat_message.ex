defmodule IntellectualClub.Chat.ChatMessage do
  @moduledoc """
  A message inside a chat.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.MessageContentFts
  alias IntellectualClub.Chat.Changes.SetFinishedAtFromStatus
  alias IntellectualClub.Chat.Changes.SetChatLastMessage
  alias IntellectualClub.Chat.Changes.SetDefaultParentFromChatLastMessage
  alias IntellectualClub.Chat.Changes.ValidateParentMessage
  alias IntellectualClub.Chat.Validations.PreventDestroyWithChildren
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  sqlite do
    table("chat_messages")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chat_messages")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :role, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:user, :assistant])
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:done)
      constraints(one_of: [:generating, :done, :canceled, :error])
    end

    attribute :error_detail, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :token_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :finished_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
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

    belongs_to :parent, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration,
      allow_nil?: true,
      attribute_type: :integer

    has_many :steps, IntellectualClub.Chat.ChatMessageStep do
      destination_attribute(:chat_message_id)
    end

    has_many :children, __MODULE__ do
      destination_attribute(:parent_id)
    end
  end

  json_api do
    type "chat-messages"
  end

  actions do
    defaults([:read])

    read :fts_search do
      argument :fts_match, :string do
        allow_nil?(false)
      end

      modify_query({MessageContentFts, :modify_message_query, []})
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      validate(PreventDestroyWithChildren)
      change(cascade_destroy(:steps, after_action?: false))
    end

    destroy :destroy_with_children do
      require_atomic?(false)
      change(cascade_destroy(:children, action: :destroy_with_children, after_action?: false))
      change(cascade_destroy(:steps, after_action?: false))
    end

    create :add_message do
      accept([
        :chat_id,
        :role,
        :parent_id,
        :llm_configuration_id,
        :status,
        :error_detail,
        :token_count
      ])

      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent, :llm_configuration], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
      change({SetFinishedAtFromStatus, []})
      change({SetChatLastMessage, []})
    end

    create :add_user_message do
      accept([:chat_id, :parent_id, :token_count])
      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})
      change({SetDefaultParentFromChatLastMessage, []})

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
      change(set_attribute(:role, :user))
      change(set_attribute(:status, :done))
      change({SetFinishedAtFromStatus, []})
      change({SetChatLastMessage, []})
    end

    create :create_generating_assistant do
      accept([:chat_id, :parent_id, :llm_configuration_id, :token_count])
      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent, :llm_configuration], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
      change(set_attribute(:role, :assistant))
      change(set_attribute(:status, :generating))
      change({SetFinishedAtFromStatus, []})
      change({SetChatLastMessage, []})
    end

    update :reparent do
      accept([:parent_id])
      require_atomic?(false)

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
    end

    update :update_token_count do
      accept([:token_count])
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

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:update) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
