defmodule IntellectualClub.Chat.ChatMessageStepRequestFile do
  @moduledoc """
  A logical file bound to the compact raw request of a chat message step.

  Each binding owns its logical file row. Multiple logical files may still share
  the same deduplicated payload.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat

  alias IntellectualClub.Files.Changes.DeleteAssociatedFile

  postgres do
    table("chat_message_step_request_files")
    repo(IntellectualClub.Repo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :reference_key, :uuid do
      allow_nil?(false)
    end

    attribute :source_file_external_id, :uuid do
      allow_nil?(false)
    end

    attribute :variant_key, :string do
      allow_nil?(false)
    end

    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :chat_message_step, IntellectualClub.Chat.ChatMessageStep,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :file, IntellectualClub.Files.File,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_step_reference, [:chat_message_step_id, :reference_key])
    identity(:unique_file, [:file_id])
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :chat_message_step_id,
        :file_id,
        :reference_key,
        :source_file_external_id,
        :variant_key
      ])
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteAssociatedFile, field: :file_id, strict?: true})
    end
  end
end
