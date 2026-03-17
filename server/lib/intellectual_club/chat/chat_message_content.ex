defmodule IntellectualClub.Chat.ChatMessageContent do
  @moduledoc """
  A content block inside a `ChatMessageItem`.

  Text blocks store text payloads. Opaque blocks store provider-specific JSON.
  Media blocks reference a stored `File`.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.MessageContentFts
  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  sqlite do
    table("chat_message_contents")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chat_message_contents")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :external_id, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1)
    end

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:text, :opaque, :media])
    end

    attribute :content_text, :string do
      allow_nil?(false)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :content_json, :map do
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

    belongs_to :chat_message_item, IntellectualClub.Chat.ChatMessageItem,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :file, IntellectualClub.Files.File,
      allow_nil?: true,
      attribute_type: :integer
  end

  identities do
    identity(:unique_item_sequence, [:chat_message_item_id, :sequence])
    identity(:unique_external_id, [:external_id])
  end

  json_api do
    type "chat-message-contents"
  end

  actions do
    defaults([:read, :destroy])

    read :fts_search do
      argument :fts_match, :string do
        allow_nil?(false)
      end

      modify_query({MessageContentFts, :modify_content_query, []})
    end

    create :create do
      accept([:chat_message_item_id, :sequence, :kind, :content_text, :content_json, :file_id])
      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:chat_message_item]})
    end

    update :update do
      accept([:sequence, :kind, :content_text, :content_json, :file_id])
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
