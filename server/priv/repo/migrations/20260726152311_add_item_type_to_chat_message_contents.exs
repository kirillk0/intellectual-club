defmodule IntellectualClub.Repo.Migrations.AddItemTypeToChatMessageContents do
  use Ecto.Migration

  @searchable_item_types """
  'input',
  'handoff_request',
  'handoff_context',
  'handoff_history',
  'handoff_message',
  'answer',
  'handoff_summary'
  """

  def up do
    alter table(:chat_message_contents) do
      add :item_type, :text
    end

    execute("""
    UPDATE chat_message_contents AS content
    SET item_type = item.type
    FROM chat_message_items AS item
    WHERE item.id = content.chat_message_item_id
    """)

    alter table(:chat_message_contents) do
      modify :item_type, :text, null: false
    end

    execute("""
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

    execute("""
    CREATE TRIGGER chat_message_contents_set_item_type
    BEFORE INSERT OR UPDATE OF chat_message_item_id, item_type
    ON chat_message_contents
    FOR EACH ROW
    EXECUTE FUNCTION set_chat_message_content_item_type()
    """)

    execute("""
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

    execute("""
    CREATE TRIGGER chat_message_contents_sync_item_type
    AFTER UPDATE OF type
    ON chat_message_items
    FOR EACH ROW
    WHEN (OLD.type IS DISTINCT FROM NEW.type)
    EXECUTE FUNCTION sync_chat_message_content_item_type()
    """)

    execute("""
    CREATE INDEX chat_message_contents_searchable_content_text_trgm_index
    ON chat_message_contents
    USING gin (content_text gin_trgm_ops)
    WHERE kind = 'text' AND item_type IN (#{@searchable_item_types})
    """)

    execute("DROP INDEX chat_message_contents_content_text_trgm_index")
  end

  def down do
    execute("""
    CREATE INDEX chat_message_contents_content_text_trgm_index
    ON chat_message_contents
    USING gin (content_text gin_trgm_ops)
    WHERE kind = 'text'
    """)

    execute("DROP INDEX chat_message_contents_searchable_content_text_trgm_index")

    execute("DROP TRIGGER chat_message_contents_sync_item_type ON chat_message_items")
    execute("DROP FUNCTION sync_chat_message_content_item_type()")
    execute("DROP TRIGGER chat_message_contents_set_item_type ON chat_message_contents")
    execute("DROP FUNCTION set_chat_message_content_item_type()")

    alter table(:chat_message_contents) do
      remove :item_type
    end
  end
end
