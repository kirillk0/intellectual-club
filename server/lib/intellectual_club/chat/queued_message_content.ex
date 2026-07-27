defmodule IntellectualClub.Chat.QueuedMessageContent do
  @moduledoc """
  A durable text or media block owned by a queued chat message.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Files.Changes.DeleteAssociatedFile
  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  postgres do
    table("chat_queued_message_contents")
    repo(IntellectualClub.Repo)

    references do
      reference(:queued_message, on_delete: :delete)
    end

    check_constraints do
      check_constraint(:kind, "chat_queued_message_contents_kind_check",
        check: "kind IN ('text', 'media')"
      )

      check_constraint(
        [:kind, :file_id],
        "chat_queued_message_contents_kind_file_check",
        check:
          "(kind = 'text' AND file_id IS NULL) OR " <>
            "(kind = 'media' AND file_id IS NOT NULL)"
      )
    end

    custom_indexes do
      index([:file_id], name: "chat_queued_message_contents_file_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:text, :media])
    end

    attribute :content_text, :string do
      allow_nil?(false)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :queued_message, IntellectualClub.Chat.QueuedMessage,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :file, IntellectualClub.Files.File,
      allow_nil?: true,
      attribute_type: :integer,
      public?: true
  end

  identities do
    identity(:unique_message_sequence, [:queued_message_id, :sequence])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:queued_message_id, :sequence, :kind, :content_text, :file_id])
      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:queued_message]})
    end

    update :update do
      accept([:sequence, :content_text])
      require_atomic?(false)
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteAssociatedFile, field: :file_id, strict?: true})
    end

    destroy :destroy_after_transfer do
      public?(false)
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
