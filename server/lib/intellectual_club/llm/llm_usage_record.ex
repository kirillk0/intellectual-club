defmodule IntellectualClub.Llm.LlmUsageRecord do
  @moduledoc """
  Durable LLM usage accounting record.

  Chat message steps keep usage fields as a local trace snapshot. This resource is
  the long-lived accounting surface used for cross-user configuration usage.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Llm,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table("llm_usage_records")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("llm_usage_records")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :external_id, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :usage_user_id_snapshot, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :usage_username_snapshot, :string do
      allow_nil?(false)
      public?(true)
      constraints(allow_empty?: false)
    end

    attribute :configuration_owner_id_snapshot, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :llm_configuration_id_snapshot, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :llm_configuration_external_id_snapshot, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :llm_configuration_label_snapshot, :string do
      allow_nil?(false)
      public?(true)
      constraints(allow_empty?: false)
    end

    attribute :provider_id_snapshot, :integer do
      allow_nil?(true)
      public?(true)
      constraints(min: 1)
    end

    attribute :provider_name_snapshot, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_type_snapshot, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :chat_id_snapshot, :integer do
      allow_nil?(false)
      constraints(min: 1)
    end

    attribute :chat_message_id_snapshot, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :chat_message_step_id_snapshot, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :step_sequence, :integer do
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

    attribute :response_final, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :input_tokens, :integer do
      allow_nil?(true)
      constraints(min: 0)
    end

    attribute :output_tokens, :integer do
      allow_nil?(true)
      constraints(min: 0)
    end

    attribute :cached_input_tokens, :integer do
      allow_nil?(true)
      constraints(min: 0)
    end

    attribute :reasoning_tokens, :integer do
      allow_nil?(true)
      constraints(min: 0)
    end

    attribute :cost, :float do
      allow_nil?(true)
      public?(true)
      constraints(min: 0.0)
    end

    attribute :raw_usage, :map do
      allow_nil?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :usage_user, IntellectualClub.Accounts.User do
      allow_nil?(true)
      attribute_type(:integer)
    end

    belongs_to :configuration_owner, IntellectualClub.Accounts.User do
      allow_nil?(true)
      attribute_type(:integer)
    end

    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration do
      allow_nil?(true)
      attribute_type(:integer)
    end

    belongs_to :provider, IntellectualClub.Llm.LlmProvider do
      allow_nil?(true)
      attribute_type(:integer)
    end

    belongs_to :chat, IntellectualClub.Chat.Chat do
      allow_nil?(true)
      attribute_type(:integer)
    end

    belongs_to :chat_message, IntellectualClub.Chat.ChatMessage do
      allow_nil?(true)
      attribute_type(:integer)
    end

    belongs_to :chat_message_step, IntellectualClub.Chat.ChatMessageStep do
      allow_nil?(true)
      attribute_type(:integer)
    end
  end

  identities do
    identity(:unique_external_id, [:external_id])
    identity(:unique_step_snapshot, [:chat_message_step_id_snapshot])
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :external_id,
        :usage_user_id,
        :usage_user_id_snapshot,
        :usage_username_snapshot,
        :configuration_owner_id,
        :configuration_owner_id_snapshot,
        :llm_configuration_id,
        :llm_configuration_id_snapshot,
        :llm_configuration_external_id_snapshot,
        :llm_configuration_label_snapshot,
        :provider_id,
        :provider_id_snapshot,
        :provider_name_snapshot,
        :provider_type_snapshot,
        :chat_id,
        :chat_id_snapshot,
        :chat_message_id,
        :chat_message_id_snapshot,
        :chat_message_step_id,
        :chat_message_step_id_snapshot,
        :step_sequence,
        :status,
        :response_final,
        :occurred_at,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :raw_usage
      ])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(usage_user_id_snapshot == ^actor(:id))
      authorize_if expr(configuration_owner_id_snapshot == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end
  end
end
