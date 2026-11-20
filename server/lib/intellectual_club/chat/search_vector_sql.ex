defmodule IntellectualClub.Chat.SearchVectorSQL do
  @moduledoc false

  # The canonical texts are read only behind the authorized Ash message resource.
  @input "('input','handoff_request','handoff_history','handoff_message')"
  @answer "('answer','handoff_summary')"
  @visible "('input','handoff_request','handoff_history','handoff_message','answer','handoff_summary')"
  @item_fields "chat_message_step_id,owner_id,sequence,type"
  @step_fields "chat_message_id,owner_id,sequence"

  def statements do
    [
      function(:ic_search_lexemes, "body text", "text", """
      RETURNS tsvector LANGUAGE plpgsql IMMUTABLE STRICT AS $$
      BEGIN
        -- The built-in text parser treats hosts, emails and paths as compound tokens.
        -- Split ASCII punctuation without treating Unicode combining marks as word breaks.
        body := regexp_replace(normalize(body, NFC) COLLATE "C", '[[:punct:]]+', ' ', 'g');
        -- PostgreSQL limits a single tsvector to 1 MiB. Preserve the source
        -- message even for pathological inputs with huge distinct vocabularies.
        LOOP
          BEGIN
            RETURN to_tsvector('pg_catalog.simple'::regconfig, body);
          EXCEPTION WHEN program_limit_exceeded THEN
            body := left(body, length(body) / 2);
          END;
        END LOOP;
      END $$
      """),
      function(:ic_message_search_documents, "ids bigint[]", "bigint[]", """
      RETURNS TABLE(message_id bigint, search_owner bigint, body text) LANGUAGE sql STABLE AS $$
        WITH messages AS MATERIALIZED (
          SELECT m.id, m.owner_id, m.role FROM chat_messages m
          WHERE m.id = ANY(ids)
          UNION ALL
          SELECT m.id, m.owner_id, m.role FROM chat_messages m WHERE ids IS NULL
        ), items AS (
          SELECT m.id AS mid, s.sequence AS ss, s.id AS sid, i.sequence AS ii, i.id AS iid,
                 string_agg(c.content_text, '' ORDER BY c.sequence, c.id) AS body
          FROM messages m
          JOIN chat_message_steps s ON s.chat_message_id = m.id AND s.owner_id = m.owner_id
          JOIN chat_message_items i ON i.chat_message_step_id = s.id AND i.owner_id = m.owner_id
          JOIN chat_message_contents c ON c.chat_message_item_id = i.id AND c.owner_id = m.owner_id
          WHERE c.kind = 'text' AND (
            (m.role = 'user' AND i.type IN #{@input}) OR
            (m.role = 'assistant' AND i.type IN #{@answer})
          )
          GROUP BY m.id, s.sequence, s.id, i.sequence, i.id
        ), documents AS (
          SELECT x.mid, string_agg(x.body, chr(10) || chr(10) ORDER BY x.ss, x.sid, x.ii, x.iid) AS body
          FROM items x WHERE x.body !~ '^[[:space:]]*$' GROUP BY x.mid
        )
        SELECT m.id, m.owner_id, coalesce(d.body, '') FROM messages m LEFT JOIN documents d ON d.mid = m.id
      $$
      """),
      function(:ic_message_search_vectors, "ids bigint[]", "bigint[]", """
      RETURNS TABLE(message_id bigint, search_owner bigint, lex tsvector) LANGUAGE sql STABLE AS $$
        SELECT d.message_id, d.search_owner, ic_search_lexemes(d.body) FROM ic_message_search_documents(ids) d
      $$
      """),
      function(:ic_refresh_message_search, "ids bigint[]", "bigint[]", """
      RETURNS void LANGUAGE plpgsql VOLATILE AS $$
      BEGIN
        IF coalesce(cardinality(ids), 0) = 0 THEN RETURN; END IF;
        -- Most leaf rows already exist and were locked by the trace revision trigger.
        -- Older messages and moves may also need a leaf without incrementing revision.
        INSERT INTO chat_message_poll_revisions (chat_message_id, revision)
          SELECT m.id, 0 FROM chat_messages m WHERE m.id = ANY(ids) AND NOT EXISTS (
            SELECT 1 FROM chat_message_poll_revisions r WHERE r.chat_message_id=m.id
          ) ORDER BY m.id ON CONFLICT DO NOTHING;
        PERFORM r.chat_message_id FROM chat_message_poll_revisions r
          WHERE r.chat_message_id = ANY(ids) ORDER BY r.chat_message_id FOR NO KEY UPDATE;
        -- Obtain a fresh snapshot after any wait. Never lock or update the generation fence.
        WITH fresh AS MATERIALIZED (SELECT * FROM ic_message_search_vectors(ids))
        UPDATE chat_message_poll_revisions r SET search_owner_id=f.search_owner, search_vector=f.lex FROM fresh f
        WHERE r.chat_message_id = ANY(ids) AND r.chat_message_id=f.message_id
          AND (r.search_owner_id,r.search_vector) IS DISTINCT FROM (f.search_owner,f.lex);
      END $$
      """),
      function(:ic_lock_trace_reparent, "", "", """
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        -- Only administrative FK rewrites share this transaction lock (ICFT, MOVE).
        -- Multi-statement maintenance must take it before any other trace writes,
        -- or run offline. Normal text, status, and ordering writes never take it.
        PERFORM pg_advisory_xact_lock(1229145684, 1297045061);
        RETURN NULL;
      END $$
      """),
      reparent_trigger(:content, "chat_message_contents", "chat_message_item_id"),
      reparent_trigger(:item, "chat_message_items", "chat_message_step_id"),
      reparent_trigger(:step, "chat_message_steps", "chat_message_id"),
      content_refresh(:insert, "NEW TABLE AS delta", visible_delta()),
      content_refresh(:delete, "OLD TABLE AS delta", visible_delta()),
      content_refresh(:update, "OLD TABLE AS previous NEW TABLE AS current_rows", """
      SELECT DISTINCT s.chat_message_id FROM previous o JOIN current_rows n USING (id)
        CROSS JOIN LATERAL (VALUES (o.chat_message_item_id),(n.chat_message_item_id)) d(iid)
        JOIN chat_message_items i ON i.id=d.iid JOIN chat_message_steps s ON s.id=i.chat_message_step_id
        WHERE CASE WHEN i.type IN #{@visible} AND (o.kind='text' OR n.kind='text') THEN
          (o.chat_message_item_id,o.owner_id,o.sequence,o.kind) IS DISTINCT FROM
          (n.chat_message_item_id,n.owner_id,n.sequence,n.kind) OR o.content_text IS DISTINCT FROM n.content_text
        ELSE false END
      """),
      # In a data-modifying CTE the content's old item or step may already be
      # gone when the contents trigger runs. The parent's transition still has its FK.
      delta_refresh(:item_delete, "chat_message_items", "DELETE", "OLD TABLE AS delta", """
      SELECT DISTINCT s.chat_message_id FROM delta i JOIN chat_message_steps s ON s.id=i.chat_message_step_id
      WHERE i.type IN #{@visible}
      """),
      delta_refresh(
        :step_delete,
        "chat_message_steps",
        "DELETE",
        "OLD TABLE AS delta",
        "SELECT DISTINCT chat_message_id FROM delta"
      ),
      function(:ic_refresh_search_structure, "", "", """
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_TABLE_NAME = 'chat_message_items' THEN
          -- Even an apparently empty item can have a concurrent first fragment.
          IF OLD.type IN #{@visible} OR NEW.type IN #{@visible} THEN
            PERFORM ic_refresh_message_search(ARRAY(
              SELECT s.chat_message_id FROM chat_message_steps s WHERE s.id IN (OLD.chat_message_step_id, NEW.chat_message_step_id)
            ));
          END IF;
        ELSIF TG_TABLE_NAME = 'chat_message_steps' THEN
          PERFORM ic_refresh_message_search(ARRAY[OLD.chat_message_id, NEW.chat_message_id]);
        ELSE
          PERFORM ic_refresh_message_search(ARRAY[NEW.id]);
        END IF;
        RETURN NULL;
      END $$
      """),
      structure_trigger(:item, "chat_message_items", @item_fields),
      structure_trigger(:step, "chat_message_steps", @step_fields),
      structure_trigger(:message, "chat_messages", "owner_id,role"),
      {:baseline_message_search_vectors,
       """
       INSERT INTO chat_message_poll_revisions AS r (chat_message_id,revision,search_owner_id,search_vector)
         SELECT f.message_id,0,f.search_owner,f.lex FROM ic_message_search_vectors(NULL::bigint[]) f
         WHERE f.lex <> ''::tsvector
         ON CONFLICT (chat_message_id) DO UPDATE
           SET search_owner_id=EXCLUDED.search_owner_id, search_vector=EXCLUDED.search_vector
           WHERE (r.search_owner_id,r.search_vector) IS DISTINCT FROM (EXCLUDED.search_owner_id,EXCLUDED.search_vector)
       """, "SELECT 1"}
    ]
    |> List.flatten()
  end

  defp function(name, params, types, body),
    do:
      {name, "CREATE FUNCTION #{name}(#{params}) #{body}",
       "DROP FUNCTION IF EXISTS #{name}(#{types})"}

  defp trigger(name, table, event, body),
    do:
      {name, "CREATE TRIGGER #{name} #{event} ON #{table} #{body}",
       "DROP TRIGGER IF EXISTS #{name} ON #{table}"}

  defp visible_delta,
    do: """
    SELECT DISTINCT s.chat_message_id FROM delta d
      JOIN chat_message_items i ON i.id=d.chat_message_item_id AND i.type IN #{@visible}
      JOIN chat_message_steps s ON s.id=i.chat_message_step_id WHERE d.kind='text'
    """

  defp reparent_trigger(type, table, parent) do
    trigger(
      :"ic_lock_#{type}_reparent",
      table,
      "BEFORE UPDATE OF #{parent}",
      "FOR EACH STATEMENT EXECUTE FUNCTION ic_lock_trace_reparent()"
    )
  end

  defp content_refresh(event, transition, changed),
    do: delta_refresh(:"content_#{event}", "chat_message_contents", event, transition, changed)

  defp delta_refresh(key, table, event, transition, changed) do
    name = :"ic_refresh_search_after_#{key}"

    [
      function(name, "", "", """
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM ic_refresh_message_search(ARRAY(#{changed}));
        RETURN NULL;
      END $$
      """),
      trigger(
        :"refresh_search_after_#{key}",
        table,
        "AFTER #{event}",
        "REFERENCING #{transition} FOR EACH STATEMENT EXECUTE FUNCTION #{name}()"
      )
    ]
  end

  defp columns(prefix, names),
    do: names |> String.split(",") |> Enum.map_join(",", &"#{prefix}.#{&1}")

  defp structure_trigger(type, table, fields) do
    # Trigger names sort after both advance_*_trace_revision and item-type sync.
    # Empty parent INSERTs need no work.
    trigger(
      :"z_search_after_#{type}_move",
      table,
      "AFTER UPDATE OF #{fields}",
      "FOR EACH ROW WHEN ((#{columns("OLD", fields)}) IS DISTINCT FROM (#{columns("NEW", fields)})) EXECUTE FUNCTION ic_refresh_search_structure()"
    )
  end
end
