defmodule IntellectualClub.Repo.Migrations.MergeLegacyHandoffFamilies do
  @moduledoc """
  Retires cross-chat handoffs without depending on the removed Ash/runtime API.

  Only entire, quiescent, same-owner chains with equivalent access are merged.
  Side branches of the selected message path move along with their chat and stay
  branches; the terminal chat's bot, configuration and note win, as they would
  after an ordinary in-chat change. Families with unfinished work, several
  continuations of one chat, conflicting ACLs or drafts are detached, never
  partially merged or discarded. Nothing is canceled: a family that still has
  active generations, queues or background tasks is logged and left detached,
  so a release upgrade never fails on a busy chat.
  Provider requests, request encodings, billing snapshots and trace IDs are not
  rewritten. The only new trace record is an empty history item before an old
  summary; the old `<continued in new chat>` history placeholder is replaced by
  readable text. This data migration is intentionally irreversible.
  """

  use Ecto.Migration

  require Logger

  @chat_refs ~w(chat_id root_chat_id source_chat_id target_chat_id fork_chat_id spawn_chat_id lineage_root_chat_id)
  @terminal ~w(done error canceled)
  @legacy_placeholder "<continued in new chat>"
  @placeholder "[Context was compacted at this point.]"
  # Leave the merged revision usable by ChatDraft's bigint-safe save/consume API.
  @max_draft_revision 9_223_372_036_854_775_806
  @tables ~w(chats chat_messages chat_message_steps chat_message_items chat_message_contents
    chat_activities chat_read_states chat_drafts chat_shares chat_tool_bindings
    chat_knowledge_blocks chat_queued_messages chat_queued_message_contents
    chat_upload_sessions background_tasks llm_usage_records)

  def up, do: execute(fn -> migrate(repo()) end)

  def down do
    raise "Legacy handoff merging is irreversible; restore the pre-migration database backup."
  end

  # Kept in the migration, not in application code, for repeatable behavior tests.
  def migrate(repo) do
    repo.transaction(
      fn ->
        sql(repo, "LOCK TABLE #{Enum.join(@tables, ", ")} IN SHARE ROW EXCLUSIVE MODE")
        chats = rows(repo, "SELECT to_jsonb(c) FROM chats c") |> Map.new(&{&1["id"], &1})
        families = families(chats)

        Enum.each(families, fn ids ->
          case plan(repo, chats, ids) do
            {:ok, chain, roots} -> merge(repo, chain, roots)
            :skip -> :ok
          end
        end)

        # Skipped, orphaned and cyclic children become visible, ordinary chats.
        # A surviving genuine fork/spawn root is deliberately not touched. The
        # chat's own activity timestamp is preserved so detached chats do not
        # resurface as recently updated.
        sql(repo, """
        UPDATE chats SET parent_relation_kind = NULL, parent_chat_id = NULL,
          parent_message_id = NULL, parent_tool_call_item_id = NULL,
          parent_tool_instance_id = NULL, fork_source_step_id = NULL,
          fork_task = NULL, fork_unavailable_functions = NULL, subagent = FALSE
        WHERE parent_relation_kind = 'handoff'
        """)

        # The item-type trigger updates the denormalized content discriminator.
        sql(repo, "UPDATE chat_message_items SET type = 'input' WHERE type = 'handoff_context'")

        sql(repo, """
        UPDATE chat_message_contents c SET item_type = i.type
        FROM chat_message_items i
        WHERE c.chat_message_item_id = i.id AND c.item_type = 'handoff_context'
        """)

        # The old chain boundary placeholder is rendered into every later prompt
        # and the UI; it is neither a provider request nor a response payload.
        sql(
          repo,
          """
          UPDATE chat_message_contents SET content_json =
            jsonb_set(content_json, '{entry_kind}', '"message"'::jsonb),
            content_text = CASE WHEN content_text = $1 THEN $2 ELSE content_text END
          WHERE item_type = 'handoff_history' AND content_json->>'entry_kind' = 'continuation'
          """,
          [@legacy_placeholder, @placeholder]
        )

        :ok
      end,
      timeout: :infinity
    )
  end

  defp families(chats) do
    edges =
      chats
      |> Map.values()
      |> Enum.filter(&(&1["parent_relation_kind"] == "handoff"))
      |> Enum.reduce(%{}, fn child, edges ->
        id = child["id"]
        parent = child["parent_chat_id"]
        edges = Map.put_new(edges, id, [])

        if Map.has_key?(chats, parent) do
          edges |> Map.update!(id, &[parent | &1]) |> Map.update(parent, [id], &[id | &1])
        else
          edges
        end
      end)

    edges
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce({[], MapSet.new()}, fn id, {result, seen} ->
      if MapSet.member?(seen, id) do
        {result, seen}
      else
        component = connected([id], edges, MapSet.new())
        {[Enum.sort(component) | result], MapSet.union(seen, component)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp connected([], _edges, seen), do: seen

  defp connected([id | rest], edges, seen) do
    if MapSet.member?(seen, id),
      do: connected(rest, edges, seen),
      else: connected(Map.get(edges, id, []) ++ rest, edges, MapSet.put(seen, id))
  end

  # Everything the retired runtime could still be driving for these chats. Such
  # a family is detached rather than merged under an orphaned or live worker.
  defp in_flight(repo, ids) do
    rows(
      repo,
      """
      SELECT to_jsonb(b) FROM (
        SELECT 'message' AS kind, m.id::text AS id FROM chat_messages m
        WHERE m.status NOT IN ('done', 'error', 'canceled') AND (
          m.chat_id = ANY($1) OR m.generation_recovery->>'completion_effect' = 'manual_handoff'
          OR EXISTS (SELECT 1 FROM chat_message_steps s
            JOIN chat_message_items i ON i.chat_message_step_id = s.id
            JOIN chat_message_contents c ON c.chat_message_item_id = i.id
            WHERE s.chat_message_id = m.id AND c.content_json #> '{raw,handoff}' IS NOT NULL)
          OR EXISTS (SELECT 1 FROM chat_message_steps s
            JOIN chat_message_items i ON i.chat_message_step_id = s.id
            WHERE s.chat_message_id = m.parent_id AND i.type = 'handoff_request'))
        UNION ALL
        SELECT 'step', s.id::text FROM chat_message_steps s
          JOIN chat_messages m ON m.id = s.chat_message_id
          WHERE m.chat_id = ANY($1) AND s.status NOT IN ('done', 'error', 'canceled')
        UNION ALL
        SELECT 'queue', q.id::text FROM chat_queued_messages q
          WHERE q.chat_id = ANY($1) AND q.status NOT IN ('delivered', 'canceled')
        UNION ALL
        SELECT 'background_task', t.id::text FROM background_tasks t
          WHERE t.status NOT IN ('completed', 'failed', 'canceled') AND (
            t.source_chat_id = ANY($1) OR t.target_chat_id = ANY($1)
            OR EXISTS (SELECT 1 FROM chat_messages m WHERE m.chat_id = ANY($1)
              AND m.id IN (t.source_message_id, t.lifecycle_message_id))
            OR EXISTS (SELECT 1 FROM chat_message_steps s
              JOIN chat_messages m ON m.id = s.chat_message_id
              WHERE m.chat_id = ANY($1) AND (s.id = t.source_step_id OR EXISTS (
                SELECT 1 FROM chat_message_items i WHERE i.chat_message_step_id = s.id
                  AND i.id = t.source_tool_call_item_id)))
            OR EXISTS (SELECT 1 FROM (
              SELECT * FROM jsonb_each_text(t.execution_context)
              UNION ALL SELECT * FROM jsonb_each_text(t.runner_ref)) r
              WHERE r.key = ANY($2) AND r.value = ANY(SELECT unnest($1::bigint[])::text)))
      ) b ORDER BY kind, id
      """,
      [ids, @chat_refs]
    )
  end

  defp plan(repo, chats, ids) do
    family = Enum.map(ids, &Map.fetch!(chats, &1))
    roots = Enum.reject(family, &(&1["parent_relation_kind"] == "handoff"))
    children = Enum.filter(family, &(&1["parent_relation_kind"] == "handoff"))
    by_parent = Enum.group_by(children, & &1["parent_chat_id"])

    with :ok <- quiescent(repo, ids),
         [root] <- roots,
         true <- Enum.all?(by_parent, fn {_id, children} -> length(children) == 1 end),
         chain = walk_chats(root, by_parent),
         true <- length(chain) == length(family),
         true <- compatible_chats?(chain),
         messages =
           rows(repo, "SELECT to_jsonb(m) FROM chat_messages m WHERE chat_id = ANY($1)", [ids]),
         {:ok, message_roots} <- linear_messages(repo, chain, messages),
         true <- compatible_dependencies?(repo, chain),
         true <- supported_summaries?(repo, tl(chain), message_roots) do
      {:ok, chain, message_roots}
    else
      _ -> :skip
    end
  end

  defp quiescent(repo, ids) do
    case in_flight(repo, ids) do
      [] ->
        :ok

      blockers ->
        details = Enum.map_join(blockers, ", ", &"#{&1["kind"]}=#{&1["id"]}")

        Logger.warning(
          "Legacy handoff family chats=#{inspect(ids)} is left as separate chats " <>
            "because work is still active (#{details}); nothing was canceled"
        )

        :skip
    end
  end

  defp walk_chats(chat, by_parent) do
    case Map.get(by_parent, chat["id"], []) do
      [] -> [chat]
      [child] -> [chat | walk_chats(child, by_parent)]
    end
  end

  defp compatible_chats?([root | children] = chain) do
    # A bot/configuration/note change in a continuation is the same as changing
    # it in a live chat: the terminal (latest) value wins and nothing is erased
    # except an older note that the terminal chat already replaced. Ownership,
    # subagent lineage and its governing tool instance must agree.
    root["parent_chat_id"] not in Enum.map(chain, & &1["id"]) and
      Enum.all?(children, fn child ->
        Enum.all?(
          ~w(owner_id subagent parent_tool_instance_id),
          &(child[&1] == root[&1])
        ) and
          child["created_at"] >= root["created_at"] and
          is_nil(child["fork_task"]) and is_nil(child["fork_source_step_id"]) and
          is_nil(child["fork_unavailable_functions"])
      end)
  end

  defp linear_messages(repo, chain, messages) do
    by_chat = Enum.group_by(messages, & &1["chat_id"])
    by_id = Map.new(messages, &{&1["id"], &1})
    ids = Map.keys(by_id)

    external =
      rows(
        repo,
        """
        SELECT to_jsonb(m) FROM chat_messages m
        WHERE parent_id = ANY($1) AND NOT (id = ANY($1))
        """,
        [ids]
      )

    # Every message of a chat moves, including side branches from edits and
    # regenerations, which simply remain branches. Only the selected path must
    # be well formed: it ends at the chat's leaf and starts at the single root
    # the continuation anchor leads back to. Other message roots stay separate
    # roots of the merged chat.
    roots =
      Enum.reduce_while(chain, %{}, fn chat, roots ->
        local = Map.get(by_chat, chat["id"], [])
        local_by_id = Map.new(local, &{&1["id"], &1})
        children = Enum.group_by(local, & &1["parent_id"])

        with true <-
               Enum.all?(
                 local,
                 &(&1["owner_id"] == chat["owner_id"] and &1["status"] in @terminal)
               ),
             %{} = leaf <- local_by_id[chat["last_message_id"]],
             [] <- Map.get(children, leaf["id"], []),
             [first | _] <- selected_path(leaf, local_by_id) do
          {:cont, Map.put(roots, chat["id"], first)}
        else
          _ -> {:halt, :invalid}
        end
      end)

    links_valid? =
      Enum.all?(tl(chain), fn child ->
        parent = Enum.find(chain, &(&1["id"] == child["parent_chat_id"]))
        anchor = by_id[child["parent_message_id"]]

        parent && anchor && anchor["chat_id"] == parent["id"] &&
          anchor["id"] == parent["last_message_id"] && valid_tool_anchor?(repo, child)
      end)

    if roots != :invalid and external == [] and links_valid?, do: {:ok, roots}, else: :skip
  end

  # The selected path from the leaf back to its root, oldest first. Returns
  # :invalid for a cycle or a parent outside the chat.
  defp selected_path(leaf, local_by_id), do: selected_path(leaf, local_by_id, [], MapSet.new())

  defp selected_path(message, local_by_id, acc, seen) do
    id = message["id"]

    cond do
      MapSet.member?(seen, id) ->
        :invalid

      is_nil(message["parent_id"]) ->
        [message | acc]

      true ->
        case local_by_id[message["parent_id"]] do
          nil -> :invalid
          parent -> selected_path(parent, local_by_id, [message | acc], MapSet.put(seen, id))
        end
    end
  end

  defp valid_tool_anchor?(_repo, %{"parent_tool_call_item_id" => nil}), do: true

  defp valid_tool_anchor?(repo, child) do
    rows(
      repo,
      """
      SELECT to_jsonb(i) FROM chat_message_items i
        JOIN chat_message_steps s ON s.id = i.chat_message_step_id
      WHERE i.id = $1 AND i.type = 'tool_call' AND s.chat_message_id = $2
        AND i.owner_id = $3 AND s.owner_id = $3
      """,
      [child["parent_tool_call_item_id"], child["parent_message_id"], child["owner_id"]]
    ) != []
  end

  defp compatible_dependencies?(repo, chain) do
    ids = Enum.map(chain, & &1["id"])
    owner = hd(chain)["owner_id"]

    equivalent? =
      Enum.all?(~w(chat_shares chat_tool_bindings chat_knowledge_blocks), fn table ->
        bindings = rows(repo, "SELECT to_jsonb(b) FROM #{table} b WHERE chat_id = ANY($1)", [ids])
        by_chat = Enum.group_by(bindings, & &1["chat_id"])

        signatures =
          Enum.map(ids, fn id ->
            Map.get(by_chat, id, [])
            |> Enum.map(&Map.drop(&1, ~w(id chat_id created_at updated_at)))
            |> Enum.sort()
          end)

        length(Enum.uniq(signatures)) == 1 and
          Enum.all?(bindings, &(Map.get(&1, "owner_id", owner) == owner))
      end)

    hazards =
      rows(
        repo,
        """
        SELECT to_jsonb(b) FROM (
          SELECT 'draft' AS kind FROM chat_drafts WHERE chat_id = ANY($1)
            GROUP BY user_id
            HAVING count(DISTINCT chat_id) FILTER (WHERE text <> '') > 1
              OR min(revision) < 0 OR max(revision) >= #{@max_draft_revision}
          UNION ALL
          SELECT 'upload' FROM chat_upload_sessions
            WHERE chat_id = ANY($1) AND (status = 'uploading' OR owner_id <> $2)
          UNION ALL
          SELECT 'owner' FROM chat_message_steps s JOIN chat_messages m ON m.id = s.chat_message_id
            WHERE m.chat_id = ANY($1) AND s.owner_id <> $2
          UNION ALL
          SELECT 'owner' FROM chat_message_items i
            JOIN chat_message_steps s ON s.id = i.chat_message_step_id
            JOIN chat_messages m ON m.id = s.chat_message_id
            WHERE m.chat_id = ANY($1) AND i.owner_id <> $2
          UNION ALL
          SELECT 'owner' FROM chat_message_contents c
            JOIN chat_message_items i ON i.id = c.chat_message_item_id
            JOIN chat_message_steps s ON s.id = i.chat_message_step_id
            JOIN chat_messages m ON m.id = s.chat_message_id
            WHERE m.chat_id = ANY($1) AND c.owner_id <> $2
          UNION ALL
          SELECT 'queue_owner' FROM chat_queued_messages WHERE chat_id = ANY($1) AND owner_id <> $2
        ) b
        """,
        [ids, owner]
      )

    states = read_states(repo, ids)

    snoozes_compatible? =
      states
      |> Enum.group_by(& &1["user_id"])
      |> Enum.all?(fn {_user, states} ->
        values = Enum.map(states, & &1["snoozed_until"])
        values = if length(states) < length(ids), do: [nil | values], else: values
        length(Enum.uniq(values)) == 1
      end)

    equivalent? and hazards == [] and snoozes_compatible?
  end

  defp supported_summaries?(repo, children, roots) do
    Enum.all?(children, fn chat ->
      root = roots[chat["id"]]

      steps =
        rows(repo, "SELECT to_jsonb(s) FROM chat_message_steps s WHERE chat_message_id = $1", [
          root["id"]
        ])

      items = summary_items(repo, root["id"])

      root["role"] == "user" and length(steps) == 1 and
        Enum.all?(items, &(is_nil(&1["tool_call_item_id"]) and &1["sequence"] > 0)) and
        case items do
          [old] ->
            old["type"] in ~w(input handoff_context) and summary_contents?(repo, old)

          [history, summary] ->
            history["type"] == "handoff_history" and summary["type"] == "handoff_message" and
              summary["sequence"] == history["sequence"] + 1 and summary_contents?(repo, summary)

          _ ->
            false
        end
    end)
  end

  defp summary_contents?(repo, item) do
    rows(
      repo,
      """
      SELECT to_jsonb(c) FROM chat_message_contents c
      WHERE chat_message_item_id = $1 AND (content_text <> '' OR file_id IS NOT NULL)
      """,
      [item["id"]]
    ) != []
  end

  defp summary_items(repo, message_id) do
    rows(
      repo,
      """
      SELECT to_jsonb(i) FROM chat_message_items i
      JOIN chat_message_steps s ON s.id = i.chat_message_step_id
      WHERE s.chat_message_id = $1 ORDER BY s.sequence, i.sequence, i.id
      """,
      [message_id]
    )
  end

  defp merge(repo, [root | children] = chain, roots) do
    root_id = root["id"]
    ids = Enum.map(chain, & &1["id"])
    removed_ids = Enum.map(children, & &1["id"])
    terminal = List.last(chain)

    merge_read_state(repo, root_id, ids)
    merge_drafts(repo, root_id, ids)

    Enum.each(children, fn child ->
      first = roots[child["id"]]

      case summary_items(repo, first["id"]) do
        [old] ->
          # There is exactly one item in this step, so the unique sequence index
          # cannot collide. Original item/content/file IDs remain unchanged.
          sql(
            repo,
            "UPDATE chat_message_items SET type = 'handoff_message', sequence = 2 WHERE id = $1",
            [old["id"]]
          )

          sql(
            repo,
            """
            INSERT INTO chat_message_items (owner_id, chat_message_step_id, sequence, type, created_at, updated_at)
            SELECT owner_id, chat_message_step_id, 1, 'handoff_history', created_at, updated_at
            FROM chat_message_items WHERE id = $1
            """,
            [old["id"]]
          )

        _modern_pair ->
          :ok
      end

      sql(repo, "UPDATE chat_messages SET parent_id = $1 WHERE id = $2", [
        child["parent_message_id"],
        first["id"]
      ])
    end)

    for table <- ~w(chat_messages llm_usage_records chat_queued_messages chat_upload_sessions) do
      sql(repo, "UPDATE #{table} SET chat_id = $1 WHERE chat_id = ANY($2)", [root_id, removed_ids])
    end

    # Includes genuine fork/spawn children off any member of this family.
    sql(repo, "UPDATE chats SET parent_chat_id = $1 WHERE parent_chat_id = ANY($2)", [
      root_id,
      removed_ids
    ])

    remap_tasks(repo, root_id, removed_ids)

    # The merged chat was last touched when its newest member was; an empty
    # terminal note falls back to the latest note still present in the chain.
    sql(
      repo,
      """
      UPDATE chats SET last_message_id = $2, bot_id = $3, llm_configuration_id = $4,
        note = $5, updated_at = $6::text::timestamp WHERE id = $1
      """,
      [
        root_id,
        terminal["last_message_id"],
        terminal["bot_id"],
        terminal["llm_configuration_id"],
        merged_note(chain),
        chain |> Enum.map(& &1["updated_at"]) |> Enum.max()
      ]
    )

    # Only equivalent redundant bindings/ACLs and already-folded per-chat state
    # are deleted. Messages and every dependent trace have been moved first.
    for table <-
          ~w(chat_shares chat_tool_bindings chat_knowledge_blocks chat_read_states chat_activities) do
      sql(repo, "DELETE FROM #{table} WHERE chat_id = ANY($1)", [removed_ids])
    end

    guard_remaining_references!(repo, removed_ids)
    sql(repo, "DELETE FROM chats WHERE id = ANY($1)", [removed_ids])
  end

  defp merged_note(chain) do
    chain
    |> Enum.reverse()
    |> Enum.map(& &1["note"])
    |> Enum.find("", &(&1 not in [nil, ""]))
  end

  # Future/extension tables must not silently cascade data away. Check the actual
  # FK catalog after known transfers, while all writes are still transactional.
  defp guard_remaining_references!(repo, removed_ids) do
    references =
      rows(repo, """
      SELECT jsonb_build_object('table', format('%I.%I', n.nspname, t.relname),
        'column', quote_ident(a.attname))
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(c.conkey)
      WHERE c.contype = 'f' AND c.confrelid = 'chats'::regclass
      """)

    Enum.each(references, fn reference ->
      table = reference["table"]
      column = reference["column"]
      sql(repo, "LOCK TABLE #{table} IN SHARE ROW EXCLUSIVE MODE")

      case sql(repo, "SELECT 1 FROM #{table} WHERE #{column} = ANY($1) LIMIT 1", [removed_ids]).rows do
        [] ->
          :ok

        _ ->
          raise "Cannot merge legacy handoffs: unmigrated dependency #{table}.#{column}. " <>
                  "Extend this data migration to preserve that dependency before retrying."
      end
    end)
  end

  defp merge_drafts(repo, root_id, ids) do
    # Planning guarantees at most one nonempty draft per user and a safe revision
    # increment. Keep that text's timestamp (or the latest empty tombstone's), not
    # the migration time. Advance even an existing root-only draft so stale clients
    # cannot overwrite moved text or resurrect consumed drafts after the merge.
    sql(
      repo,
      """
      INSERT INTO chat_drafts (chat_id, user_id, text, revision, updated_at)
      SELECT $1, user_id, coalesce(max(text) FILTER (WHERE text <> ''), ''),
        max(revision) + 1,
        coalesce(max(updated_at) FILTER (WHERE text <> ''), max(updated_at))
      FROM chat_drafts WHERE chat_id = ANY($2) GROUP BY user_id
      ON CONFLICT (chat_id, user_id) DO UPDATE SET text = EXCLUDED.text,
        revision = EXCLUDED.revision, updated_at = EXCLUDED.updated_at
      """,
      [root_id, ids]
    )

    # Remove folded rows before the FK guard; never rely on chat deletion cascades.
    sql(repo, "DELETE FROM chat_drafts WHERE chat_id = ANY($1) AND chat_id <> $2", [ids, root_id])
  end

  defp read_states(repo, ids),
    do: rows(repo, "SELECT to_jsonb(s) FROM chat_read_states s WHERE chat_id = ANY($1)", [ids])

  defp merge_read_state(repo, root_id, ids) do
    activities =
      rows(repo, "SELECT to_jsonb(a) FROM chat_activities a WHERE chat_id = ANY($1)", [ids])

    revisions = Map.new(activities, &{&1["chat_id"], &1["revision"]})
    revision = Enum.sum(Map.values(revisions))

    read_states(repo, ids)
    |> Enum.group_by(& &1["user_id"])
    |> Enum.each(fn {user, states} ->
      by_chat = Map.new(states, &{&1["chat_id"], &1})

      unread? =
        Enum.any?(ids, fn id ->
          Map.get(revisions, id, 0) > Map.get(Map.get(by_chat, id, %{}), "read_revision", 0)
        end)

      read = if unread?, do: max(revision - 1, 0), else: revision
      manual = Enum.any?(states, & &1["manual_unread"])
      version = Enum.reduce(states, 1, &(&1["state_version"] + &2))
      snooze = hd(states)["snoozed_until"]

      sql(
        repo,
        """
        INSERT INTO chat_read_states (chat_id, user_id, read_revision, manual_unread, snoozed_until, state_version)
        VALUES ($1, $2, $3, $4, $5::text::timestamp, $6)
        ON CONFLICT (chat_id, user_id) DO UPDATE SET read_revision = EXCLUDED.read_revision,
          manual_unread = EXCLUDED.manual_unread, snoozed_until = EXCLUDED.snoozed_until,
          state_version = EXCLUDED.state_version
        """,
        [root_id, user, read, manual, snooze, version]
      )
    end)

    sql(
      repo,
      """
      INSERT INTO chat_activities (chat_id, revision) VALUES ($1, $2)
      ON CONFLICT (chat_id) DO UPDATE SET revision = EXCLUDED.revision
      """,
      [root_id, revision]
    )
  end

  defp remap_tasks(repo, root_id, removed_ids) do
    for field <- ~w(source_chat_id target_chat_id) do
      sql(repo, "UPDATE background_tasks SET #{field} = $1 WHERE #{field} = ANY($2)", [
        root_id,
        removed_ids
      ])
    end

    # Only known operational references are changed, not arbitrary tool arguments,
    # historical tool results, provider payloads or immutable usage snapshots.
    for column <- ~w(execution_context runner_ref), field <- @chat_refs do
      sql(
        repo,
        """
        UPDATE background_tasks SET #{column} = jsonb_set(#{column}, ARRAY[$1::text], to_jsonb($2::bigint))
        WHERE #{column}->>$1 = ANY(SELECT unnest($3::bigint[])::text)
        """,
        [field, root_id, removed_ids]
      )
    end

    for field <- ~w(fork_url spawn_url url) do
      sql(
        repo,
        """
        UPDATE background_tasks SET runner_ref = jsonb_set(runner_ref, ARRAY[$1::text], to_jsonb($2::text))
        WHERE runner_ref->>$1 = ANY(SELECT '/chats/' || unnest($3::bigint[])::text)
        """,
        [field, "/chats/#{root_id}", removed_ids]
      )
    end
  end

  defp sql(repo, statement, params \\ []),
    do: repo.query!(statement, params, timeout: :infinity)

  defp rows(repo, statement, params \\ []),
    do: Enum.map(sql(repo, statement, params).rows, fn [row] -> row end)
end
