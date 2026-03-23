defmodule IntellectualClub.Chat.ChatUploadSession do
  @moduledoc """
  A short-lived server-backed upload session for large chat attachments.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  sqlite do
    table("chat_upload_sessions")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chat_upload_sessions")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :external_id, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :filename, :string do
      allow_nil?(false)
    end

    attribute :mime_type, :string do
      allow_nil?(false)
    end

    attribute :size_bytes, :integer do
      allow_nil?(false)
      constraints(min: 1)
    end

    attribute :uploaded_bytes, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
    end

    attribute :chunk_size_bytes, :integer do
      allow_nil?(false)
      constraints(min: 1)
    end

    attribute :status, :atom do
      allow_nil?(false)
      default(:uploading)
      constraints(one_of: [:uploading, :uploaded, :aborted, :expired])
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil?(false)
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
  end

  identities do
    identity(:unique_external_id, [:external_id])
  end

  actions do
    defaults([:read, :destroy])

    create :start do
      accept([
        :chat_id,
        :filename,
        :mime_type,
        :size_bytes,
        :uploaded_bytes,
        :chunk_size_bytes,
        :status,
        :expires_at
      ])

      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})
    end

    update :track_progress do
      accept([:uploaded_bytes, :status, :expires_at])
      require_atomic?(false)
    end

    update :mark_status do
      accept([:status, :expires_at])
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
