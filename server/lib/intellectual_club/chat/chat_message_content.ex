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

  alias IntellectualClub.Files.Changes.DeleteAssociatedFile
  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor

  postgres do
    table("chat_message_contents")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:file_id], name: "chat_message_contents_file_id_index")
    end

    custom_statements do
      statement :chat_message_contents_set_item_type_function do
        up("""
        CREATE OR REPLACE FUNCTION set_chat_message_content_item_type()
        RETURNS trigger AS $$
        BEGIN
          SELECT type
          INTO NEW.item_type
          FROM chat_message_items
          WHERE id = NEW.chat_message_item_id;

          IF NEW.item_type IS NULL THEN
            RAISE EXCEPTION 'Cannot resolve item type for chat message item %', NEW.chat_message_item_id;
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        down("DROP FUNCTION IF EXISTS set_chat_message_content_item_type()")
      end

      statement :chat_message_contents_set_item_type_trigger do
        up("""
        CREATE TRIGGER chat_message_contents_set_item_type
        BEFORE INSERT OR UPDATE OF chat_message_item_id, item_type
        ON chat_message_contents
        FOR EACH ROW
        EXECUTE FUNCTION set_chat_message_content_item_type()
        """)

        down(
          "DROP TRIGGER IF EXISTS chat_message_contents_set_item_type ON chat_message_contents"
        )
      end

      statement :chat_message_contents_sync_item_type_function do
        up("""
        CREATE OR REPLACE FUNCTION sync_chat_message_content_item_type()
        RETURNS trigger AS $$
        BEGIN
          UPDATE chat_message_contents
          SET item_type = NEW.type
          WHERE chat_message_item_id = NEW.id
            AND item_type IS DISTINCT FROM NEW.type;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        down("DROP FUNCTION IF EXISTS sync_chat_message_content_item_type()")
      end

      statement :chat_message_contents_sync_item_type_trigger do
        up("""
        CREATE TRIGGER chat_message_contents_sync_item_type
        AFTER UPDATE OF type
        ON chat_message_items
        FOR EACH ROW
        WHEN (OLD.type IS DISTINCT FROM NEW.type)
        EXECUTE FUNCTION sync_chat_message_content_item_type()
        """)

        down("DROP TRIGGER IF EXISTS chat_message_contents_sync_item_type ON chat_message_items")
      end

      statement :chat_message_contents_searchable_content_text_trgm_index do
        up(
          "CREATE INDEX IF NOT EXISTS chat_message_contents_searchable_content_text_trgm_index ON chat_message_contents USING gin (content_text gin_trgm_ops) WHERE kind = 'text' AND item_type IN ('input', 'handoff_request', 'handoff_context', 'handoff_history', 'handoff_message', 'answer', 'handoff_summary')"
        )

        down("DROP INDEX IF EXISTS chat_message_contents_searchable_content_text_trgm_index")
      end
    end
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

    attribute :item_type, :atom do
      allow_nil?(false)
      generated?(true)
      writable?(false)

      constraints(
        one_of: [
          :input,
          :handoff_request,
          :handoff_context,
          :handoff_history,
          :handoff_message,
          :steering,
          :reasoning,
          :answer,
          :handoff_summary,
          :tool_call,
          :tool_result,
          :artifact,
          :error,
          :other
        ]
      )
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
    defaults([:read])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteAssociatedFile, field: :file_id})
    end

    create :create do
      accept([
        :chat_message_item_id,
        :external_id,
        :sequence,
        :kind,
        :content_text,
        :content_json,
        :file_id
      ])

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

      authorize_if expr(
                     chat_message_item.chat_message_step.chat_message.chat.shared_incoming == true
                   )
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
