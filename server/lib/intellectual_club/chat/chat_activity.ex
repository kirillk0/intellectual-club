defmodule IntellectualClub.Chat.ChatActivity do
  @moduledoc """
  Terminal generation activity, isolated from chat/message locking.

  The trigger only locks this leaf row after the message. No writer locks this
  row before a chat or message, preserving the chat -> message lock order.
  Historical messages deliberately start at revision zero.
  """
  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("chat_activities")
    repo(IntellectualClub.Repo)

    references do
      reference(:chat, on_delete: :delete)
    end

    custom_statements do
      statement :initialize_chat_activity do
        up("""
        CREATE OR REPLACE FUNCTION initialize_chat_activity() RETURNS trigger AS $$
        BEGIN
          INSERT INTO chat_activities (chat_id, revision) VALUES (NEW.id, 0);
          RETURN NULL;
        END;
        $$ LANGUAGE plpgsql;
        """)

        down("DROP FUNCTION IF EXISTS initialize_chat_activity()")
      end

      statement :chat_initial_activity do
        up(
          "CREATE TRIGGER chat_initial_activity AFTER INSERT ON chats FOR EACH ROW EXECUTE FUNCTION initialize_chat_activity()"
        )

        down("DROP TRIGGER IF EXISTS chat_initial_activity ON chats")
      end

      statement :baseline_chat_activity do
        up(
          "INSERT INTO chat_activities (chat_id, revision) SELECT id, 0 FROM chats ON CONFLICT (chat_id) DO NOTHING"
        )

        down("SELECT 1")
      end

      statement :advance_chat_activity do
        up("""
        CREATE OR REPLACE FUNCTION advance_chat_activity() RETURNS trigger AS $$
        BEGIN
          IF OLD.status = 'generating' AND NEW.status IN ('done', 'error', 'canceled')
             AND NEW.role = 'assistant' THEN
            UPDATE chat_activities SET revision = revision + 1 WHERE chat_id = NEW.chat_id;
          END IF;
          RETURN NULL;
        END;
        $$ LANGUAGE plpgsql;
        """)

        down("DROP FUNCTION IF EXISTS advance_chat_activity()")
      end

      statement :chat_terminal_activity do
        up(
          "CREATE TRIGGER chat_terminal_activity AFTER UPDATE OF status ON chat_messages FOR EACH ROW EXECUTE FUNCTION advance_chat_activity()"
        )

        down("DROP TRIGGER IF EXISTS chat_terminal_activity ON chat_messages")
      end
    end
  end

  attributes do
    attribute :chat_id, :integer, primary_key?: true, allow_nil?: false
    attribute :revision, :integer, allow_nil?: false, default: 0
  end

  relationships do
    belongs_to :chat, IntellectualClub.Chat.Chat,
      define_attribute?: false,
      attribute_type: :integer,
      allow_nil?: false
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(chat.owner_id == ^actor(:id))
      authorize_if expr(chat.shared_incoming == true)
    end
  end
end
