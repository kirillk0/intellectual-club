defmodule IntellectualClub.Chat.ChatMessageStep do
  @moduledoc """
  One generation step for an assistant message.

  An assistant message can contain multiple immutable logical requests. Use
  `IntellectualClub.Generation.StepRequests` to reconstruct their compact JSON;
  `raw_request` is only the physical full-checkpoint field.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.Changes.CleanupLinkedForks
  alias IntellectualClub.Chat.Changes.PreventStepRequestMutation
  alias IntellectualClub.Chat.Changes.RewriteStepRequestEncoding
  alias IntellectualClub.Chat.Changes.ValidateStepRequest
  alias IntellectualClub.Chat.Changes.SetFinishedAtFromStatus
  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  postgres do
    table("chat_message_steps")
    repo(IntellectualClub.Repo)
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
      select_by_default?(false)
    end

    attribute :request_mode, :atom do
      allow_nil?(false)
      default(:full)
      constraints(one_of: [:full, :patch])
    end

    attribute :request_patch, {:array, :map} do
      allow_nil?(true)
      select_by_default?(false)
    end

    attribute :request_hash, :string do
      allow_nil?(true)
    end

    attribute :request_base_hash, :string do
      allow_nil?(true)
    end

    attribute :request_base_sequence, :integer do
      allow_nil?(true)
      constraints(min: 1)
    end

    attribute :request_checkpoint_distance, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0, max: 32)
    end

    attribute :raw_response, :map do
      allow_nil?(true)
      select_by_default?(false)
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

    attribute :last_token_at, :utc_datetime_usec do
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
    belongs_to(:owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer
    )

    belongs_to(:chat_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: false,
      attribute_type: :integer
    )

    has_many :items, IntellectualClub.Chat.ChatMessageItem do
      destination_attribute(:chat_message_step_id)
    end

    has_many :request_files, IntellectualClub.Chat.ChatMessageStepRequestFile do
      destination_attribute(:chat_message_step_id)
    end
  end

  identities do
    identity(:unique_chat_message_sequence, [:chat_message_id, :sequence])
  end

  json_api do
    type("chat-message-steps")
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({CleanupLinkedForks, []})

      change(
        {IntellectualClub.Chat.Changes.CascadeDestroyInCleanup,
         relationship: :items, after_action?: false}
      )

      change(
        {IntellectualClub.Chat.Changes.CascadeDestroyInCleanup,
         relationship: :request_files, after_action?: false}
      )
    end

    create :create do
      # A transient optimization, verified against the persisted predecessor hash.
      argument :request_base, :map do
        public?(false)
      end

      accept([
        :chat_message_id,
        :sequence,
        :status,
        :raw_request,
        :request_mode,
        :request_patch,
        :request_hash,
        :request_base_hash,
        :request_base_sequence,
        :request_checkpoint_distance,
        :raw_response,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :first_token_at,
        :last_token_at,
        :finished_at
      ])

      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:chat_message]})
      change({SetFinishedAtFromStatus, []})
      change(ValidateStepRequest)
    end

    create :create_request do
      public?(false)

      argument :request, :map do
        allow_nil?(false)
        public?(false)
      end

      argument :request_base, :map do
        public?(false)
      end

      argument :request_base_step_id, :integer do
        public?(false)
      end

      argument :force_full, :boolean do
        default(false)
        allow_nil?(false)
        public?(false)
      end

      argument :max_chain, :integer do
        default(32)
        allow_nil?(false)
        constraints(min: 1, max: 32)
        public?(false)
      end

      accept([
        :chat_message_id,
        :sequence,
        :status,
        :raw_response,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :first_token_at,
        :last_token_at,
        :finished_at
      ])

      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:chat_message]})
      change({SetFinishedAtFromStatus, []})
      change({ValidateStepRequest, logical?: true})
    end

    update :update do
      accept([
        :status,
        :raw_response,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :first_token_at,
        :last_token_at,
        :finished_at
      ])

      require_atomic?(false)
      change(PreventStepRequestMutation)
    end

    update :rewrite_request_encoding do
      public?(false)
      require_atomic?(false)
      accept([])

      argument :encoding, :map do
        allow_nil?(false)
        public?(false)
      end

      change(RewriteStepRequestEncoding)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(relates_to_actor_via(:owner))

      authorize_if(expr(chat_message.chat.shared_incoming == true))
    end

    policy action_type(:create) do
      authorize_if(actor_present())
    end

    policy action_type([:update, :destroy]) do
      authorize_if(relates_to_actor_via(:owner))
    end
  end
end
