defmodule IntellectualClub.Repo.Migrations.ArchiveOrphanedSubchats do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION archive_detached_subchat() RETURNS trigger AS $$
    BEGIN
      -- An explicit edit can temporarily disconnect a live fork from an
      -- existing parent. Only FK detachment and the orphan backfill promote it.
      IF OLD.parent_chat_id IS NOT NULL AND EXISTS (SELECT 1 FROM chats WHERE id = OLD.parent_chat_id) THEN
        RETURN NEW;
      END IF;

      NEW.subagent := FALSE;
      NEW.parent_relation_kind := NULL;
      NEW.parent_message_id := NULL;
      NEW.parent_tool_call_item_id := NULL;
      NEW.parent_tool_instance_id := NULL;
      NEW.fork_source_step_id := NULL;
      NEW.fork_task := NULL;
      NEW.fork_unavailable_functions := NULL;

      INSERT INTO chat_read_states AS s (chat_id, user_id, archived_revision, state_version)
      VALUES (NEW.id, NEW.owner_id,
              COALESCE((SELECT revision FROM chat_activities WHERE chat_id = NEW.id), 0), 1)
      ON CONFLICT (chat_id, user_id) DO UPDATE
        SET archived_revision = EXCLUDED.archived_revision, state_version = s.state_version + 1;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    # A foreign-owned legacy copy survives the owner's cascade. The parent FK
    # detaches it, so promote it to a visible archived chat for its own owner.
    execute("""
    CREATE TRIGGER archive_detached_subchat BEFORE UPDATE OF parent_chat_id ON chats
    FOR EACH ROW WHEN (NEW.subagent AND NEW.parent_chat_id IS NULL)
    EXECUTE FUNCTION archive_detached_subchat()
    """)

    # Apply the same transition to previously detached roots. Their descendants
    # remain attached and inherit the restored root's archive visibility.
    execute("UPDATE chats SET parent_chat_id = NULL WHERE subagent AND parent_chat_id IS NULL")
  end

  def down do
    execute("DROP TRIGGER archive_detached_subchat ON chats")
    execute("DROP FUNCTION archive_detached_subchat()")
  end
end
