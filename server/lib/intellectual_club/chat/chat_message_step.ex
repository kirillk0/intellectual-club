defmodule IntellectualClub.Chat.ChatMessageStep do
  @moduledoc """
  One generation step for an assistant message.

  A single assistant `ChatMessage` can contain multiple steps in the future
  (tool calling loop, retries, etc). For P0 we persist the first step only.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.Changes.SetFinishedAtFromStatus
  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  sqlite do
    table("chat_message_steps")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chat_message_steps")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:done)
      constraints(one_of: [:waiting_provider, :waiting_tools, :done, :canceled, :error])
    end

    attribute :raw_request, :map do
      allow_nil?(false)
      default(%{})
    end

    attribute :raw_response, :map do
      allow_nil?(true)
    end

    attribute :response_final, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :input_tokens, :integer do
      allow_nil?(true)
      public?(true)
      constraints(min: 0)
    end

    attribute :output_tokens, :integer do
      allow_nil?(true)
      public?(true)
      constraints(min: 0)
    end

    attribute :cached_input_tokens, :integer do
      allow_nil?(true)
      public?(true)
      constraints(min: 0)
    end

    attribute :reasoning_tokens, :integer do
      allow_nil?(true)
      public?(true)
      constraints(min: 0)
    end

    attribute :cost, :float do
      allow_nil?(true)
      public?(true)
      constraints(min: 0.0)
    end

    attribute :first_token_at, :utc_datetime_usec do
      allow_nil?(true)
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

    belongs_to :chat_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: false,
      attribute_type: :integer

    has_many :items, IntellectualClub.Chat.ChatMessageItem do
      destination_attribute(:chat_message_step_id)
    end
  end

  identities do
    identity(:unique_chat_message_sequence, [:chat_message_id, :sequence])
  end

  json_api do
    type "chat-message-steps"
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      change(cascade_destroy(:items, after_action?: false))
    end

    create :create do
      accept([
        :chat_message_id,
        :sequence,
        :status,
        :raw_request,
        :raw_response,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :first_token_at
      ])

      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:chat_message]})
      change({SetFinishedAtFromStatus, []})
    end

    update :update do
      accept([
        :sequence,
        :status,
        :raw_request,
        :raw_response,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :first_token_at
      ])

      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(chat_message.chat.shared_incoming == true)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
