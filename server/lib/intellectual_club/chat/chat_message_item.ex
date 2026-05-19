defmodule IntellectualClub.Chat.ChatMessageItem do
  @moduledoc """
  An item inside a `ChatMessageStep`.

  Items represent high-level pieces of the model output such as reasoning,
  final answer text, tool calls, tool results, and errors.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  sqlite do
    table("chat_message_items")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chat_message_items")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :type, :atom do
      allow_nil?(false)
      public?(true)

      constraints(
        one_of: [:input, :reasoning, :answer, :tool_call, :tool_result, :artifact, :error, :other]
      )
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :chat_message_step, IntellectualClub.Chat.ChatMessageStep,
      allow_nil?: false,
      attribute_type: :integer

    has_many :contents, IntellectualClub.Chat.ChatMessageContent do
      destination_attribute(:chat_message_item_id)
    end
  end

  identities do
    identity(:unique_step_sequence, [:chat_message_step_id, :sequence])
  end

  json_api do
    type "chat-message-items"
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      change(cascade_destroy(:contents, after_action?: false))
    end

    create :create do
      accept([:chat_message_step_id, :sequence, :type])
      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:chat_message_step]})
    end

    update :update do
      accept([:sequence, :type])
      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(chat_message_step.chat_message.chat.shared_incoming == true)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
