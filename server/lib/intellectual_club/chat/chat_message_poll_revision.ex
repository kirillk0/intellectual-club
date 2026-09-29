defmodule IntellectualClub.Chat.ChatMessagePollRevision do
  @moduledoc """
  Transactional trace invalidation, separate from the generation fence row.

  Database-derived revisions cover bulk writes and cascades. This resource is
  read-only to callers; all access is authorized through its owning message.
  """
  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("chat_message_poll_revisions")
    repo(IntellectualClub.Repo)

    references do
      reference(:chat_message, on_delete: :delete)
    end

    custom_statements do
      statement :advance_message_trace_revision do
        up("""
        CREATE OR REPLACE FUNCTION advance_message_trace_revision()
        RETURNS trigger AS $$
        DECLARE message_id bigint;
        BEGIN
          IF TG_TABLE_NAME = 'chat_message_steps' THEN
            message_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.chat_message_id ELSE NEW.chat_message_id END;
          ELSIF TG_TABLE_NAME = 'chat_message_items' THEN
            SELECT chat_message_id INTO message_id FROM chat_message_steps
              WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.chat_message_step_id ELSE NEW.chat_message_step_id END;
          ELSE
            SELECT s.chat_message_id INTO message_id FROM chat_message_items i
              JOIN chat_message_steps s ON s.id = i.chat_message_step_id
              WHERE i.id = CASE WHEN TG_OP = 'DELETE' THEN OLD.chat_message_item_id ELSE NEW.chat_message_item_id END;
          END IF;
          INSERT INTO chat_message_poll_revisions (chat_message_id, revision)
            SELECT id, 1 FROM chat_messages WHERE id = message_id
            ON CONFLICT (chat_message_id) DO UPDATE
              SET revision = chat_message_poll_revisions.revision + 1;
          RETURN NULL;
        END;
        $$ LANGUAGE plpgsql;
        """)

        down("DROP FUNCTION IF EXISTS advance_message_trace_revision()")
      end

      statement :advance_step_trace_revision do
        up(
          "CREATE TRIGGER advance_step_trace_revision AFTER INSERT OR UPDATE OR DELETE ON chat_message_steps FOR EACH ROW EXECUTE FUNCTION advance_message_trace_revision()"
        )

        down("DROP TRIGGER IF EXISTS advance_step_trace_revision ON chat_message_steps")
      end

      statement :advance_item_trace_revision do
        up(
          "CREATE TRIGGER advance_item_trace_revision AFTER INSERT OR UPDATE OR DELETE ON chat_message_items FOR EACH ROW EXECUTE FUNCTION advance_message_trace_revision()"
        )

        down("DROP TRIGGER IF EXISTS advance_item_trace_revision ON chat_message_items")
      end

      statement :advance_content_trace_revision do
        up(
          "CREATE TRIGGER advance_content_trace_revision AFTER INSERT OR UPDATE OR DELETE ON chat_message_contents FOR EACH ROW EXECUTE FUNCTION advance_message_trace_revision()"
        )

        down("DROP TRIGGER IF EXISTS advance_content_trace_revision ON chat_message_contents")
      end
    end
  end

  attributes do
    attribute :chat_message_id, :integer do
      primary_key?(true)
      allow_nil?(false)
    end

    attribute :revision, :integer do
      allow_nil?(false)
      default(0)
    end
  end

  relationships do
    belongs_to :chat_message, IntellectualClub.Chat.ChatMessage do
      define_attribute?(false)
      allow_nil?(false)
      attribute_type(:integer)
    end
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(expr(chat_message.owner_id == ^actor(:id)))
      authorize_if(expr(chat_message.chat.shared_incoming == true))
    end
  end
end
