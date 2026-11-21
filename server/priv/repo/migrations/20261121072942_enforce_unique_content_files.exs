defmodule IntellectualClub.Repo.Migrations.EnforceUniqueContentFiles do
  @moduledoc """
  Gives each persisted media content its own logical file, without copying payloads.
  The earliest attachment keeps the original file UUID and existing external links.
  """
  use Ecto.Migration

  def up do
    # Keep the ownership check, backfill and unique index in the same write fence.
    execute("""
    LOCK TABLE chat_message_contents, files, bots, chat_draft_attachments,
      chat_message_step_request_files, chat_queued_message_contents,
      knowledge_block_files, knowledge_blocks IN SHARE ROW EXCLUSIVE MODE
    """)

    execute("""
    DO $$
    DECLARE
      conflict_id bigint;
    BEGIN
      SELECT c.file_id INTO conflict_id
      FROM chat_message_contents c
      JOIN (
        SELECT image_file_id AS file_id FROM bots
        UNION ALL SELECT original_file_id FROM chat_draft_attachments
        UNION ALL SELECT compressed_file_id FROM chat_draft_attachments
        UNION ALL SELECT file_id FROM chat_message_step_request_files
        UNION ALL SELECT file_id FROM chat_queued_message_contents
        UNION ALL SELECT file_id FROM knowledge_block_files
        UNION ALL SELECT image_file_id FROM knowledge_blocks
      ) other ON other.file_id = c.file_id
      LIMIT 1;

      IF FOUND THEN
        RAISE EXCEPTION 'File % is owned by both chat_message_contents and another table; resolve before migrating', conflict_id;
      END IF;
    END $$
    """)

    execute("""
    WITH ranked AS (
      SELECT id, file_id, row_number() OVER (PARTITION BY file_id ORDER BY created_at, id) AS position
      FROM chat_message_contents
      WHERE file_id IS NOT NULL
    ), copies AS MATERIALIZED (
      SELECT id AS content_id, file_id AS source_id, gen_random_uuid() AS new_uuid
      FROM ranked WHERE position > 1
    ), inserted AS (
      INSERT INTO files (external_id, sha256, filename, size_bytes, mime_type, storage_backend, created_at)
      SELECT c.new_uuid, f.sha256, f.filename, f.size_bytes, f.mime_type, f.storage_backend,
             now() AT TIME ZONE 'UTC'
      FROM copies c JOIN files f ON f.id = c.source_id
      RETURNING id, external_id
    )
    UPDATE chat_message_contents target SET file_id = i.id
    FROM copies c JOIN inserted i ON i.external_id = c.new_uuid
    WHERE target.id = c.content_id
    """)

    create unique_index(:chat_message_contents, [:file_id],
             name: "chat_message_contents_unique_file_index"
           )

    drop_if_exists index(:chat_message_contents, [:file_id],
                     name: "chat_message_contents_file_id_index"
                   )
  end

  def down do
    # Logical copies may have acquired independent history; never merge them back.
    create index(:chat_message_contents, [:file_id], name: "chat_message_contents_file_id_index")

    drop_if_exists unique_index(:chat_message_contents, [:file_id],
                     name: "chat_message_contents_unique_file_index"
                   )
  end
end
