Code.require_file(
  "../../../priv/repo/migrations/20261101120000_merge_legacy_handoff_families.exs",
  __DIR__
)

defmodule IntellectualClub.Chat.LegacyHandoffMigrationTest do
  use IntellectualClub.DataCase, async: false

  import ExUnit.CaptureLog
  import IntellectualClub.StepRequestsFixtures

  alias IntellectualClub.Chat.{
    Chat,
    ChatDraft,
    ChatUploadSession,
    MessageBookmark,
    QueuedMessage
  }

  alias IntellectualClub.Repo.Migrations.MergeLegacyHandoffFamilies, as: Migration

  setup do
    %{user: actor} = user_fixture()
    %{user: background_actor} = user_fixture()
    background = segment(background_actor, :input)
    revision(background, 7, background_actor, 3)

    assert {:ok, %{conflict: false}} =
             ChatDraft.save(
               background.chat.id,
               %{"text" => "Unrelated private draft", "expected_revision" => 0},
               background_actor
             )

    create_usage_record!(background_actor, %{
      chat: background.chat,
      message: background.reply,
      step: background.reply_step
    })

    create_background_task!(background_actor, status: :completed, generation: background.reply)
    %{actor: actor, background_actor: background_actor}
  end

  test "merges an entire mixed four-chat chain and preserves trace IDs and immutable requests", %{
    actor: actor,
    background_actor: background_actor
  } do
    background_before = database_snapshot(background_actor)
    [root, modern, input, context] = family(actor, [:modern, :input, :handoff_context])
    ids = Enum.map([root, modern, input, context], & &1.chat.id)
    terminal_note = "Current task"
    update_chat(actor, context.chat, %{note: terminal_note})

    file =
      create!(
        IntellectualClub.Files.File,
        %{
          sha256: "migration-fixture",
          filename: "history.md",
          size_bytes: 3,
          mime_type: "text/markdown"
        },
        actor
      )

    attachment =
      create_content!(actor, input.summary, sequence: 2, kind: :media, file_id: file.id)

    bookmark = create!(MessageBookmark, %{chat_message_id: context.reply.id}, actor)

    request = %{
      "chat_id" => input.chat.id,
      "messages" => [%{"role" => "user", "content" => String.duplicate("Original ", 256)}]
    }

    immutable_step = encoded_request_step!(input.reply, 2, request, actor)

    patch_step =
      encoded_request_step!(input.reply, 3, Map.put(request, "next", true), actor,
        previous_step: immutable_step,
        previous_request: request
      )

    assert patch_step.request_mode == :patch
    assert patch_step.request_hash != nil
    assert patch_step.request_base_hash == immutable_step.request_hash

    before_steps = table_rows("chat_message_steps", actor)
    before_contents = table_rows("chat_message_contents", actor)

    before_message_ids =
      query("SELECT id FROM chat_messages WHERE owner_id = $1 ORDER BY id", [actor.id])

    before_item_ids =
      query("SELECT id FROM chat_message_items WHERE owner_id = $1 ORDER BY id", [actor.id])
      |> List.flatten()

    modern_items = items(modern.first.id)

    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query("SELECT id FROM chats WHERE owner_id = $1 ORDER BY id", [actor.id]) == [
             [root.chat.id]
           ]

    assert query("SELECT DISTINCT chat_id FROM chat_messages WHERE owner_id = $1", [actor.id]) ==
             [[root.chat.id]]

    assert query("SELECT id FROM chat_messages WHERE owner_id = $1 ORDER BY id", [actor.id]) ==
             before_message_ids

    assert table_rows("chat_message_steps", actor) == before_steps

    assert Enum.all?(
             before_item_ids,
             &(&1 in (query("SELECT id FROM chat_message_items WHERE owner_id = $1", [actor.id])
                      |> List.flatten()))
           )

    assert Ash.get!(Chat, root.chat.id, actor: actor).last_message_id == context.reply.id
    assert Ash.get!(Chat, root.chat.id, actor: actor).note == terminal_note

    assert Ash.get!(MessageBookmark, bookmark.id, actor: actor).chat_message_id ==
             context.reply.id

    assert query("SELECT file_id FROM chat_message_contents WHERE id = $1", [attachment.id]) == [
             [file.id]
           ]

    assert query("SELECT raw_request FROM chat_message_steps WHERE id = $1", [immutable_step.id]) ==
             [[request]]

    assert query("SELECT id FROM chat_message_steps WHERE id = $1", [patch_step.id]) == [
             [patch_step.id]
           ]

    assert items(modern.first.id) == modern_items

    for {parent, child} <- Enum.zip([root, modern, input], [modern, input, context]) do
      assert query("SELECT parent_id FROM chat_messages WHERE id = $1", [child.first.id]) == [
               [parent.reply.id]
             ]

      assert [[_, "handoff_history", 1], [summary_id, "handoff_message", 2]] =
               items(child.first.id)

      assert summary_id == child.summary.id
    end

    after_contents = table_rows("chat_message_contents", actor)

    assert Enum.map(after_contents, &Map.delete(&1, "item_type")) ==
             Enum.map(before_contents, &Map.delete(&1, "item_type"))

    assert query("SELECT id FROM chats WHERE id = ANY($1)", [tl(ids)]) == []

    assert query(
             "SELECT id FROM chat_message_items WHERE type = 'handoff_context' AND owner_id = $1",
             [actor.id]
           ) == []

    assert query(
             "SELECT id FROM chat_message_contents WHERE item_type = 'handoff_context' AND owner_id = $1",
             [actor.id]
           ) == []

    snapshot = database_snapshot(actor)
    assert {:ok, :ok} = Migration.migrate(Repo)
    assert database_snapshot(actor) == snapshot
    assert database_snapshot(background_actor) == background_before
  end

  test "remaps external fork/spawn, usage, completed queues, uploads and operational task references",
       %{actor: actor} do
    [root, middle, terminal] = family(actor, [:modern, :input])
    tool = create_item!(actor, terminal.reply_step, sequence: 2, type: :tool_call)

    fork =
      create_linked_chat!(actor, %{
        chat: terminal.chat,
        message: terminal.reply,
        step: terminal.reply_step,
        item: tool
      })

    spawn = create_subchat!(actor, middle.chat, :spawn, parent_message_id: middle.reply.id)

    task =
      create_background_task!(actor,
        status: :completed,
        generation: terminal.reply,
        execution_context: %{"chat_id" => terminal.chat.id, "root_chat_id" => middle.chat.id},
        target_chat_id: middle.chat.id,
        runner_ref: %{
          "fork_chat_id" => terminal.chat.id,
          "fork_message_id" => terminal.first.id,
          "fork_generation_message_id" => terminal.reply.id,
          "fork_url" => "/chats/#{terminal.chat.id}",
          "lineage_root_chat_id" => middle.chat.id
        },
        arguments: %{"chat_id" => terminal.chat.id}
      )

    task =
      task
      |> Ash.Changeset.for_update(
        :update_state,
        %{result: %{"original_chat_id" => terminal.chat.id}},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    usage =
      create_usage_record!(actor, %{
        chat: terminal.chat,
        message: terminal.reply,
        step: terminal.reply_step
      })

    queue =
      create_forcing!(
        QueuedMessage,
        :enqueue,
        %{
          chat_id: middle.chat.id,
          kind: :follow_up,
          status: :delivered,
          anchor_message_id: middle.first.id,
          assistant_message_id: middle.reply.id
        },
        actor
      )

    queued_content =
      create!(
        IntellectualClub.Chat.QueuedMessageContent,
        %{
          queued_message_id: queue.id,
          sequence: 1,
          kind: :text,
          content_text: "Preserved queue"
        },
        actor
      )

    upload =
      create_forcing!(
        ChatUploadSession,
        :start,
        %{
          chat_id: terminal.chat.id,
          filename: "done.txt",
          mime_type: "text/plain",
          size_bytes: 3,
          chunk_size_bytes: 3,
          uploaded_bytes: 3,
          status: :uploaded,
          expires_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor
      )

    original_usage = hd(table_rows("llm_usage_records", actor))
    assert {:ok, :ok} = Migration.migrate(Repo)
    assert Ash.get!(Chat, fork.id, actor: actor).parent_chat_id == root.chat.id
    assert Ash.get!(Chat, fork.id, actor: actor).fork_source_step_id == terminal.reply_step.id
    assert Ash.get!(Chat, spawn.id, actor: actor).parent_chat_id == root.chat.id

    assert query("SELECT parent_message_id FROM chats WHERE id = $1", [fork.id]) == [
             [terminal.reply.id]
           ]

    assert query("SELECT chat_id, chat_id_snapshot FROM llm_usage_records WHERE id = $1", [
             usage.id
           ]) == [[root.chat.id, terminal.chat.id]]

    assert Map.delete(hd(table_rows("llm_usage_records", actor)), "chat_id") ==
             Map.delete(original_usage, "chat_id")

    assert query("SELECT sum(cost) FROM llm_usage_records WHERE chat_id = $1", [root.chat.id]) ==
             [[0.25]]

    assert query("SELECT chat_id, assistant_message_id FROM chat_queued_messages WHERE id = $1", [
             queue.id
           ]) == [[root.chat.id, middle.reply.id]]

    assert query(
             "SELECT queued_message_id FROM chat_queued_message_contents WHERE id = $1",
             [queued_content.id]
           ) == [[queue.id]]

    assert query("SELECT chat_id FROM chat_upload_sessions WHERE id = $1", [upload.id]) == [
             [root.chat.id]
           ]

    stored = hd(table_rows("background_tasks", actor))
    assert stored["id"] == task.id
    assert stored["source_chat_id"] == root.chat.id
    assert stored["target_chat_id"] == root.chat.id
    assert stored["source_message_id"] == terminal.reply.id
    assert stored["execution_context"]["chat_id"] == root.chat.id
    assert stored["execution_context"]["root_chat_id"] == root.chat.id
    assert stored["runner_ref"]["fork_chat_id"] == root.chat.id
    assert stored["runner_ref"]["lineage_root_chat_id"] == root.chat.id
    assert stored["runner_ref"]["fork_url"] == "/chats/#{root.chat.id}"
    assert stored["runner_ref"]["fork_generation_message_id"] == terminal.reply.id
    assert stored["arguments"] == %{"chat_id" => terminal.chat.id}
    assert stored["result"] == %{"original_chat_id" => terminal.chat.id}
  end

  test "preserves genuine root subagent ancestry while detaching skipped inherited subagents", %{
    actor: actor
  } do
    anchor = create_tool_call_anchor!(actor)
    lineage_tool = create_tool_instance!(actor)
    linked = create_linked_chat!(actor, anchor, parent_tool_instance_id: lineage_tool.id)

    [root, child, terminal] =
      family(actor, [:modern, :modern],
        root: linked,
        subagent: true,
        chat_attrs: %{parent_tool_instance_id: lineage_tool.id}
      )

    ancestry =
      hd(
        query(
          "SELECT parent_chat_id, parent_message_id, parent_relation_kind, parent_tool_call_item_id, parent_tool_instance_id, fork_source_step_id, fork_task, subagent FROM chats WHERE id = $1",
          [root.chat.id]
        )
      )

    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query(
             "SELECT parent_chat_id, parent_message_id, parent_relation_kind, parent_tool_call_item_id, parent_tool_instance_id, fork_source_step_id, fork_task, subagent FROM chats WHERE id = $1",
             [root.chat.id]
           ) == [ancestry]

    assert query("SELECT id FROM chats WHERE id = ANY($1)", [[child.chat.id, terminal.chat.id]]) ==
             []

    [skipped, orphan] = family(actor, [:handoff_context], subagent: true)
    Repo.query!("UPDATE chats SET parent_chat_id = NULL WHERE id = $1", [orphan.chat.id])
    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query(
             "SELECT parent_chat_id, parent_message_id, parent_relation_kind, parent_tool_call_item_id, parent_tool_instance_id, fork_source_step_id, fork_task, subagent FROM chats WHERE id = $1",
             [orphan.chat.id]
           ) == [[nil, nil, nil, nil, nil, nil, nil, false]]

    assert query("SELECT id FROM chats WHERE id = $1", [skipped.chat.id]) == [[skipped.chat.id]]
    assert items(orphan.first.id) == [[orphan.summary.id, "input", 1]]
  end

  test "skips the entire family when one chat has several continuations", %{actor: actor} do
    [root, middle, terminal] = family(actor, [:input, :handoff_context])
    sibling = segment(actor, :modern)
    legacy_link(sibling, root)
    before_updated = query("SELECT id, updated_at FROM chats WHERE owner_id = $1", [actor.id])

    before_ids =
      query("SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id", [
        actor.id
      ])

    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query(
             "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
             [actor.id]
           ) == before_ids

    assert query("SELECT count(*) FROM chats WHERE owner_id = $1", [actor.id]) == [[4]]

    assert query(
             "SELECT count(*) FROM chats WHERE parent_relation_kind = 'handoff' AND owner_id = $1",
             [actor.id]
           ) == [[0]]

    # Detaching is not an activity: the chats keep their own timestamps.
    assert query("SELECT id, updated_at FROM chats WHERE owner_id = $1", [actor.id]) ==
             before_updated

    assert items(terminal.first.id) == [[terminal.summary.id, "input", 1]]
    assert items(middle.first.id) == [[middle.summary.id, "input", 1]]
  end

  test "side branches and extra message roots move with their chat and stay branches", %{
    actor: actor
  } do
    [root, branch, terminal] = family(actor, [:modern, :modern])
    regenerated = create_message!(actor, branch.chat, parent_id: branch.first.id)
    edited = create_message!(actor, root.chat, parent_id: root.first.id)
    canceled = create_message!(actor, terminal.chat, parent_id: terminal.first.id)
    set_message_status!(actor, canceled, :canceled)
    extra_root = create_message!(actor, branch.chat, role: :user)

    # The user went back to the original path; the side branches remain.
    for segment <- [root, branch, terminal] do
      segment.chat
      |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: segment.reply.id},
        actor: actor
      )
      |> Ash.update!(actor: actor)
    end

    before_parents =
      query("SELECT id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id", [actor.id])

    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query("SELECT id FROM chats WHERE owner_id = $1", [actor.id]) == [[root.chat.id]]

    assert query("SELECT DISTINCT chat_id FROM chat_messages WHERE owner_id = $1", [actor.id]) ==
             [[root.chat.id]]

    # Only the continuation roots are re-parented; every other link is unchanged.
    expected_parents =
      Enum.map(before_parents, fn
        [id, nil] when id == branch.first.id -> [id, root.reply.id]
        [id, nil] when id == terminal.first.id -> [id, branch.reply.id]
        row -> row
      end)

    assert query("SELECT id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id", [
             actor.id
           ]) == expected_parents

    assert query("SELECT parent_id FROM chat_messages WHERE id = ANY($1) ORDER BY id", [
             [regenerated.id, edited.id, canceled.id, extra_root.id]
           ]) == [[branch.first.id], [root.first.id], [terminal.first.id], [nil]]

    assert Ash.get!(Chat, root.chat.id, actor: actor).last_message_id == terminal.reply.id
  end

  test "a branched leaf, a dangling anchor and a foreign parent never merge", %{actor: actor} do
    for problem <- [:branched_leaf, :missing_leaf, :foreign_parent] do
      [root, middle, terminal] = family(actor, [:modern, :input])

      case problem do
        :branched_leaf ->
          create_message!(actor, middle.chat, parent_id: middle.reply.id)

        :missing_leaf ->
          Repo.query!("UPDATE chats SET last_message_id = NULL WHERE id = $1", [middle.chat.id])

        :foreign_parent ->
          Repo.query!("UPDATE chat_messages SET parent_id = $1 WHERE id = $2", [
            root.reply.id,
            middle.reply.id
          ])
      end

      before =
        query(
          "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
          [actor.id]
        )

      assert {:ok, :ok} = Migration.migrate(Repo)

      assert query(
               "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
               [actor.id]
             ) == before

      assert query("SELECT count(*) FROM chats WHERE id = ANY($1)", [
               [root.chat.id, middle.chat.id, terminal.chat.id]
             ]) == [[3]]
    end
  end

  test "cycles, nonterminal anchors and unsupported summaries never partially merge",
       %{actor: actor} do
    for problem <- [:cycle, :message_cycle, :wrong_anchor, :unsupported_summary] do
      [root, middle, terminal] = family(actor, [:modern, :input])

      case problem do
        :cycle ->
          legacy_link(root, terminal)

        :message_cycle ->
          Repo.query!("UPDATE chat_messages SET parent_id = $1 WHERE id = $2", [
            middle.reply.id,
            middle.first.id
          ])

        :wrong_anchor ->
          Repo.query!("UPDATE chats SET parent_message_id = $1 WHERE id = $2", [
            root.first.id,
            middle.chat.id
          ])

        :unsupported_summary ->
          create_text_item!(actor, terminal.first_step, "Another input",
            sequence: 2,
            type: :input
          )
      end

      before =
        query(
          "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
          [actor.id]
        )

      assert {:ok, :ok} = Migration.migrate(Repo)

      assert query(
               "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
               [actor.id]
             ) == before

      assert query("SELECT id FROM chats WHERE id = ANY($1) ORDER BY id", [
               [root.chat.id, middle.chat.id, terminal.chat.id]
             ]) == Enum.map([root, middle, terminal], &[&1.chat.id])
    end
  end

  test "owner, ACL and binding mismatches keep all chats separate", %{actor: actor} do
    %{user: other} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [actor]})

    for problem <- [:owner, :acl, :binding] do
      [root, middle, terminal] = family(actor, [:modern, :handoff_context])

      case problem do
        :owner ->
          Repo.query!("UPDATE chats SET owner_id = $1 WHERE id = $2", [other.id, middle.chat.id])

        :acl ->
          share_chat!(actor, middle.chat, group,
            bot_id: create_bot!(actor).id,
            llm_configuration_id: create_configuration!(actor).id
          )

        :binding ->
          create!(
            IntellectualClub.Tools.ChatToolBinding,
            %{chat_id: middle.chat.id, tool_instance_id: create_tool_instance!(actor).id},
            actor
          )
      end

      before =
        query(
          "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
          [actor.id]
        )

      assert {:ok, :ok} = Migration.migrate(Repo)

      assert query(
               "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
               [actor.id]
             ) == before

      assert query("SELECT count(*) FROM chats WHERE id = ANY($1)", [
               [root.chat.id, middle.chat.id, terminal.chat.id]
             ]) == [[3]]
    end
  end

  test "bot, configuration and note changes merge with the latest value winning", %{
    actor: actor
  } do
    [root, middle, terminal] = family(actor, [:modern, :handoff_context])
    bot = create_bot!(actor)
    configuration = create_configuration!(actor)
    update_chat(actor, root.chat, %{note: "Original note"})
    update_chat(actor, middle.chat, %{bot_id: create_bot!(actor).id, note: "Latest note"})
    update_chat(actor, terminal.chat, %{bot_id: bot.id, llm_configuration_id: configuration.id})
    Repo.query!("UPDATE chats SET note = NULL WHERE id = $1", [terminal.chat.id])

    Repo.query!("UPDATE chats SET updated_at = $1 WHERE id = $2", [
      ~N[2026-01-01 00:00:00],
      root.chat.id
    ])

    Repo.query!("UPDATE chats SET updated_at = $1 WHERE id = $2", [
      ~N[2026-03-01 12:00:00],
      middle.chat.id
    ])

    Repo.query!("UPDATE chats SET updated_at = $1 WHERE id = $2", [
      ~N[2026-02-01 00:00:00],
      terminal.chat.id
    ])

    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query("SELECT id FROM chats WHERE owner_id = $1", [actor.id]) == [[root.chat.id]]
    merged = Ash.get!(Chat, root.chat.id, actor: actor)
    assert merged.bot_id == bot.id
    assert merged.llm_configuration_id == configuration.id
    assert merged.note == "Latest note"
    assert merged.last_message_id == terminal.reply.id

    # The merged chat is as recent as its newest member, not the migration time.
    assert query("SELECT updated_at FROM chats WHERE id = $1", [root.chat.id]) == [
             [~N[2026-03-01 12:00:00.000000]]
           ]

    for message <- [middle.first, middle.reply, terminal.first, terminal.reply] do
      assert query("SELECT chat_id FROM chat_messages WHERE id = $1", [message.id]) == [
               [root.chat.id]
             ]
    end
  end

  test "equivalent shares and bindings are retained without broadening access", %{actor: actor} do
    %{group: group} = user_group_fixture(%{users: [actor]})
    tool = create_tool_instance!(actor)
    bot = create_bot!(actor)
    configuration = create_configuration!(actor)

    [root | children] =
      chain =
      family(actor, [:input, :modern],
        chat_attrs: %{bot_id: bot.id, llm_configuration_id: configuration.id}
      )

    for segment <- chain do
      share_chat!(actor, segment.chat, group,
        bot_id: bot.id,
        llm_configuration_id: configuration.id
      )

      create!(
        IntellectualClub.Tools.ChatToolBinding,
        %{chat_id: segment.chat.id, tool_instance_id: tool.id, enabled: false, sequence: 2},
        actor
      )
    end

    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query("SELECT chat_id, user_group_id FROM chat_shares WHERE chat_id = $1", [
             root.chat.id
           ]) == [[root.chat.id, group.id]]

    assert query(
             "SELECT chat_id, tool_instance_id, enabled, sequence FROM chat_tool_bindings WHERE chat_id = $1",
             [root.chat.id]
           ) ==
             [[root.chat.id, tool.id, false, 2]]

    assert query("SELECT id FROM chats WHERE id = ANY($1)", [Enum.map(children, & &1.chat.id)]) ==
             []
  end

  test "read revisions are evaluated per original chat and activity/unread/manual state is combined",
       %{actor: actor} do
    [root, middle, terminal] = family(actor, [:modern, :input])
    # Persisted revisions are per-chat counters, not globally comparable clocks.
    revision(root, 100, actor, 100)
    revision(middle, 1, actor, 0)
    revision(terminal, 4, actor, 4, true)
    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query("SELECT revision FROM chat_activities WHERE chat_id = $1", [root.chat.id]) == [
             [105]
           ]

    assert [[104, true, nil, 4]] ==
             query(
               "SELECT read_revision, manual_unread, snoozed_until, state_version FROM chat_read_states WHERE chat_id = $1",
               [root.chat.id]
             )

    assert query("SELECT count(*) FROM chat_read_states WHERE chat_id = ANY($1)", [
             [root.chat.id, middle.chat.id, terminal.chat.id]
           ]) == [[1]]

    [read_root, read_child] = family(actor, [:modern])
    revision(read_root, 5, actor, 5)
    revision(read_child, 2, actor, 2)
    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query("SELECT read_revision, manual_unread FROM chat_read_states WHERE chat_id = $1", [
             read_root.chat.id
           ]) == [[7, false]]
  end

  test "missing read states stay unread; consistent snoozes survive but conflicting snoozes skip",
       %{actor: actor} do
    [root, middle, terminal] = family(actor, [:modern, :input])
    revision(root, 10, actor, 10)
    Repo.query!("UPDATE chat_activities SET revision = 1 WHERE chat_id = $1", [middle.chat.id])
    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query("SELECT read_revision FROM chat_read_states WHERE chat_id = $1", [root.chat.id]) ==
             [[10]]

    assert query("SELECT id FROM chats WHERE id = $1", [terminal.chat.id]) == []

    for scenario <- [:same_snooze, :conflicting_snooze] do
      [root, child] = family(actor, [:input])
      revision(root, 2, actor, 2)
      revision(child, 1, actor, 1)

      case scenario do
        :same_snooze ->
          Repo.query!(
            "UPDATE chat_read_states SET snoozed_until = '2099-01-01' WHERE chat_id = ANY($1)",
            [[root.chat.id, child.chat.id]]
          )

        :conflicting_snooze ->
          Repo.query!(
            "UPDATE chat_read_states SET snoozed_until = '2099-01-01' WHERE chat_id = $1",
            [child.chat.id]
          )
      end

      assert {:ok, :ok} = Migration.migrate(Repo)

      if scenario == :same_snooze do
        assert [[%NaiveDateTime{year: 2099}]] =
                 query("SELECT snoozed_until FROM chat_read_states WHERE chat_id = $1", [
                   root.chat.id
                 ])

        assert query("SELECT id FROM chats WHERE id = $1", [child.chat.id]) == []
      else
        assert query("SELECT id FROM chats WHERE id = $1", [child.chat.id]) == [[child.chat.id]]
      end
    end
  end

  test "consumed empty drafts retain a newer root tombstone and reject stale clients", %{
    actor: actor
  } do
    [root, child, terminal] = family(actor, [:input, :modern])

    for segment <- [root, child] do
      assert {:ok, %{conflict: false}} =
               ChatDraft.save(
                 segment.chat.id,
                 %{"text" => "Submitted", "expected_revision" => 0},
                 actor
               )

      assert ChatDraft.consume(segment.chat.id, "Submitted", 1, actor)
    end

    assert {:ok, %{conflict: false}} =
             ChatDraft.save(
               child.chat.id,
               %{"text" => "Submitted again", "expected_revision" => 2},
               actor
             )

    assert ChatDraft.consume(child.chat.id, "Submitted again", 3, actor)
    assert {:ok, consumed} = ChatDraft.get(child.chat.id, actor)
    assert consumed.revision == 4
    assert {:ok, :ok} = Migration.migrate(Repo)
    assert {:ok, merged} = ChatDraft.get(root.chat.id, actor)
    assert merged == %{consumed | chat_id: root.chat.id, revision: 5}

    assert query(
             "SELECT chat_id, user_id, text, revision FROM chat_drafts WHERE chat_id = ANY($1)",
             [
               [root.chat.id, child.chat.id, terminal.chat.id]
             ]
           ) == [[root.chat.id, actor.id, "", 5]]

    assert query("SELECT id FROM chats WHERE id = ANY($1)", [[child.chat.id, terminal.chat.id]]) ==
             []

    for stale <- 0..4 do
      assert {:ok, %{conflict: true, draft: ^merged}} =
               ChatDraft.save(
                 root.chat.id,
                 %{"text" => "Resurrected", "expected_revision" => stale},
                 actor
               )
    end

    refute ChatDraft.consume(root.chat.id, "Submitted", 1, actor)

    assert {:ok, %{error: :not_found}} =
             ChatDraft.save(
               child.chat.id,
               %{"text" => "Resurrected", "expected_revision" => 4},
               actor
             )

    snapshot = database_snapshot(actor)
    assert {:ok, :ok} = Migration.migrate(Repo)
    assert database_snapshot(actor) == snapshot

    assert {:ok, %{conflict: false, draft: %{revision: 6, text: "New text"}}} =
             ChatDraft.save(
               root.chat.id,
               %{"text" => "New text", "expected_revision" => 5},
               actor
             )
  end

  test "a sole nonempty draft survives at the root with its exact text and original timestamp", %{
    actor: actor
  } do
    for location <- [
          :child_without_root,
          :child_with_root_empty,
          :root_with_child_empty,
          :root_only
        ] do
      [root, child] = family(actor, [:input])
      source = if location in [:root_only, :root_with_child_empty], do: root, else: child
      text = "  Keep this draft\nwith whitespace \n"

      assert {:ok, %{conflict: false}} =
               ChatDraft.save(source.chat.id, %{"text" => text, "expected_revision" => 0}, actor)

      Repo.query!(
        "UPDATE chat_drafts SET revision = 5, updated_at = '2001-01-01 01:02:03.123456' WHERE chat_id = $1 AND user_id = $2",
        [source.chat.id, actor.id]
      )

      has_empty? = location in [:child_with_root_empty, :root_with_child_empty]

      if has_empty? do
        empty = if source.chat.id == root.chat.id, do: child, else: root

        assert {:ok, %{conflict: false}} =
                 ChatDraft.save(empty.chat.id, %{"text" => "", "expected_revision" => 0}, actor)

        Repo.query!(
          "UPDATE chat_drafts SET revision = 12, updated_at = '2002-01-01' WHERE chat_id = $1 AND user_id = $2",
          [empty.chat.id, actor.id]
        )
      end

      revision = if has_empty?, do: 13, else: 6
      assert {:ok, :ok} = Migration.migrate(Repo)

      assert query(
               "SELECT chat_id, user_id, text, revision, updated_at FROM chat_drafts WHERE chat_id = ANY($1)",
               [[root.chat.id, child.chat.id]]
             ) == [[root.chat.id, actor.id, text, revision, ~N[2001-01-01 01:02:03.123456]]]

      assert query("SELECT id FROM chats WHERE id = $1", [child.chat.id]) == []

      for stale <- [0, 5, 12] do
        assert {:ok, %{conflict: true, draft: %{text: ^text, revision: ^revision}}} =
                 ChatDraft.save(
                   root.chat.id,
                   %{"text" => "Stale text", "expected_revision" => stale},
                   actor
                 )
      end

      refute ChatDraft.consume(root.chat.id, text, 5, actor)
      snapshot = database_snapshot(actor)
      assert {:ok, :ok} = Migration.migrate(Repo)
      assert database_snapshot(actor) == snapshot
    end
  end

  test "private drafts and sparse empty tombstones fold independently for each historical user",
       %{actor: actor} do
    %{user: other} = user_fixture()
    %{user: consumed_user} = user_fixture()
    [root, middle, terminal] = family(actor, [:input, :modern])
    ids = [root.chat.id, middle.chat.id, terminal.chat.id]

    # The current API only writes for the owner; SQL represents private rows left
    # by historical owners, without changing their user IDs or exposing their text.
    Repo.query!(
      """
      INSERT INTO chat_drafts (chat_id, user_id, text, revision, updated_at) VALUES
        ($1, $4, 'Owner text', 4, '2001-01-01'),
        ($3, $4, '', 10, '2003-01-01'),
        ($1, $5, '', 12, '2004-01-01'),
        ($2, $5, 'Other private text', 9, '2002-01-01'),
        ($2, $6, '', 7, '2001-01-01'),
        ($3, $6, '', 17, '2005-01-01')
      """,
      ids ++ [actor.id, other.id, consumed_user.id]
    )

    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query(
             "SELECT chat_id, user_id, text, revision, updated_at FROM chat_drafts WHERE chat_id = ANY($1) ORDER BY user_id",
             [ids]
           ) ==
             Enum.sort_by(
               [
                 [root.chat.id, actor.id, "Owner text", 11, ~N[2001-01-01 00:00:00.000000]],
                 [
                   root.chat.id,
                   other.id,
                   "Other private text",
                   13,
                   ~N[2002-01-01 00:00:00.000000]
                 ],
                 [root.chat.id, consumed_user.id, "", 18, ~N[2005-01-01 00:00:00.000000]]
               ],
               &Enum.at(&1, 1)
             )

    assert query("SELECT id FROM chats WHERE id = ANY($1)", [tl(ids)]) == []
    assert {:ok, %{text: "Owner text", revision: 11}} = ChatDraft.get(root.chat.id, actor)
    assert {:error, :not_found} = ChatDraft.get(root.chat.id, other)
    snapshot = database_snapshot(actor)
    assert {:ok, :ok} = Migration.migrate(Repo)
    assert database_snapshot(actor) == snapshot
  end

  test "two nonempty drafts for any one user keep the whole family and every draft unchanged", %{
    actor: actor
  } do
    %{user: other} = user_fixture()

    for scenario <- [:root_and_child, :two_children, :identical_text, :whitespace, :other_user] do
      [root, middle, terminal] = family(actor, [:input, :handoff_context])
      ids = [root.chat.id, middle.chat.id, terminal.chat.id]
      first = if scenario == :root_and_child, do: root, else: middle

      text =
        case scenario do
          :identical_text -> "First draft"
          :whitespace -> " \n"
          _ -> "Second draft"
        end

      user = if scenario == :other_user, do: other, else: actor

      Repo.query!(
        """
        INSERT INTO chat_drafts (chat_id, user_id, text, revision, updated_at) VALUES
          ($1, $3, 'First draft', 3, '2001-01-01'),
          ($2, $3, $4, 7, '2002-01-01')
        """,
        [first.chat.id, terminal.chat.id, user.id, text]
      )

      if scenario == :other_user do
        assert {:ok, %{conflict: false}} =
                 ChatDraft.save(
                   root.chat.id,
                   %{"text" => "Owner draft", "expected_revision" => 0},
                   actor
                 )
      end

      before_drafts = table_rows("chat_drafts", actor)
      before_messages = table_rows("chat_messages", actor)
      assert {:ok, :ok} = Migration.migrate(Repo)
      assert table_rows("chat_drafts", actor) == before_drafts
      assert table_rows("chat_messages", actor) == before_messages

      assert query("SELECT id FROM chats WHERE id = ANY($1) ORDER BY id", [ids]) ==
               Enum.map(ids, &[&1])

      assert query(
               "SELECT id FROM chats WHERE id = ANY($1) AND parent_relation_kind = 'handoff'",
               [ids]
             ) == []

      snapshot = database_snapshot(actor)
      assert {:ok, :ok} = Migration.migrate(Repo)
      assert database_snapshot(actor) == snapshot
    end
  end

  test "unadvanceable draft revisions skip the whole family instead of overflowing or becoming unusable",
       %{actor: actor} do
    max_revision = 9_223_372_036_854_775_806

    for {value, at_root?} <- [
          {-1, false},
          {max_revision - 1, false},
          {max_revision, false},
          {max_revision, true},
          {max_revision + 1, true}
        ] do
      [root, child] = family(actor, [:input])

      for {segment, text} <- [{root, ""}, {child, "Keep text"}] do
        assert {:ok, %{conflict: false}} =
                 ChatDraft.save(
                   segment.chat.id,
                   %{"text" => text, "expected_revision" => 0},
                   actor
                 )
      end

      chat_id = if at_root?, do: root.chat.id, else: child.chat.id

      Repo.query!("UPDATE chat_drafts SET revision = $1 WHERE chat_id = $2 AND user_id = $3", [
        value,
        chat_id,
        actor.id
      ])

      before_drafts = table_rows("chat_drafts", actor)
      assert {:ok, :ok} = Migration.migrate(Repo)

      if value == max_revision - 1 do
        assert {:ok, %{text: "Keep text", revision: ^max_revision}} =
                 ChatDraft.get(root.chat.id, actor)

        assert query("SELECT id FROM chats WHERE id = $1", [child.chat.id]) == []
      else
        assert table_rows("chat_drafts", actor) == before_drafts

        assert query("SELECT id FROM chats WHERE id = ANY($1) ORDER BY id", [
                 [root.chat.id, child.chat.id]
               ]) == [[root.chat.id], [child.chat.id]]
      end
    end
  end

  test "normalizes standalone old content and continuation metadata without altering provider payloads",
       %{actor: actor} do
    standalone = segment(actor, :handoff_context)
    modern = segment(actor, :modern)
    history_id = items(modern.first.id) |> hd() |> hd()

    content =
      create_content!(actor, history_id,
        content_text: "<continued in new chat>",
        content_json: %{"entry_kind" => "continuation", "role" => "assistant"}
      )

    custom =
      create_content!(actor, history_id,
        sequence: 2,
        content_text: "Kept verbatim",
        content_json: %{"entry_kind" => "continuation", "role" => "assistant"}
      )

    assert {:ok, :ok} = Migration.migrate(Repo)
    assert items(standalone.first.id) == [[standalone.summary.id, "input", 1]]

    # The sanitized UI and every later prompt render this text; the old tag-like
    # placeholder would otherwise be stripped or shown verbatim.
    assert query(
             "SELECT content_text, content_json FROM chat_message_contents WHERE id = ANY($1) ORDER BY sequence",
             [[content.id, custom.id]]
           ) == [
             [
               "[Context was compacted at this point.]",
               %{"entry_kind" => "message", "role" => "assistant"}
             ],
             ["Kept verbatim", %{"entry_kind" => "message", "role" => "assistant"}]
           ]
  end

  test "active messages, steps, pending or blocked queues and background references detach the family",
       %{actor: actor} do
    %{user: quiet_actor} = user_fixture()

    for active <- [:message, :step, :pending, :blocked, :background, :json_background] do
      [root, child] = family(actor, [:handoff_context])
      quiet = family(quiet_actor, [:modern])

      blocker =
        case active do
          :message ->
            set_message_status!(actor, child.reply, :generating)

          :step ->
            create_step!(actor, child.reply, sequence: 2, status: :waiting_tools)

          status when status in [:pending, :blocked] ->
            create_forcing!(
              QueuedMessage,
              :enqueue,
              %{chat_id: root.chat.id, kind: :follow_up, status: status},
              actor
            )

          :background ->
            create_background_task!(actor, status: :running, generation: child.reply)

          :json_background ->
            create_background_task!(actor,
              status: :queued,
              runner_ref: %{"lineage_root_chat_id" => child.chat.id}
            )
        end

      before = database_snapshot(actor)
      blocker_id = if is_binary(blocker.id), do: blocker.id, else: Integer.to_string(blocker.id)

      log =
        capture_log(fn ->
          assert {:ok, :ok} = Migration.migrate(Repo)
        end)

      assert log =~ "work is still active"
      assert log =~ "=#{blocker_id}"
      assert log =~ "chats=#{inspect(Enum.sort([root.chat.id, child.chat.id]))}"

      # Nothing is canceled or moved: the busy family only loses its link, while
      # an unrelated quiet family in the same run still merges.
      snapshot = database_snapshot(actor)

      assert Map.drop(snapshot, ~w(chats chat_message_items chat_message_contents)) ==
               Map.drop(before, ~w(chats chat_message_items chat_message_contents))

      assert query("SELECT id FROM chats WHERE id = $1", [child.chat.id]) == [[child.chat.id]]

      assert query(
               "SELECT parent_chat_id, parent_relation_kind FROM chats WHERE id = $1",
               [child.chat.id]
             ) == [[nil, nil]]

      assert items(child.first.id) == [[child.summary.id, "input", 1]]
      [quiet_root, quiet_child] = quiet
      assert query("SELECT id FROM chats WHERE id = $1", [quiet_child.chat.id]) == []

      assert query("SELECT chat_id FROM chat_messages WHERE id = $1", [quiet_child.reply.id]) == [
               [quiet_root.chat.id]
             ]
    end
  end

  test "legacy raw handoff in a nonterminal message outside any family is left untouched",
       %{actor: actor} do
    segment = segment(actor, :input)
    call = create_item!(actor, segment.reply_step, sequence: 2, type: :tool_call)

    result =
      create_item!(actor, segment.reply_step,
        sequence: 3,
        type: :tool_result,
        tool_call_item_id: call.id
      )

    create_content!(actor, result,
      kind: :opaque,
      content_json: %{"raw" => %{"handoff" => %{"chat_id" => segment.chat.id}}}
    )

    set_message_status!(actor, segment.reply, :generating)
    before = database_snapshot(actor)
    assert {:ok, :ok} = Migration.migrate(Repo)
    assert database_snapshot(actor) == before
  end

  test "all writes roll back together and down explicitly rejects reversal", %{actor: actor} do
    [root, middle, _terminal] = family(actor, [:input, :handoff_context])

    assert {:ok, %{conflict: false}} =
             ChatDraft.save(root.chat.id, %{"text" => "", "expected_revision" => 0}, actor)

    assert {:ok, %{conflict: false}} =
             ChatDraft.save(
               middle.chat.id,
               %{"text" => "Roll back this draft", "expected_revision" => 0},
               actor
             )

    before = database_snapshot(actor)

    assert {:error, :rollback_check} =
             Repo.transaction(fn ->
               assert {:ok, :ok} = Migration.migrate(Repo)
               assert query("SELECT count(*) FROM chats WHERE owner_id = $1", [actor.id]) == [[1]]

               assert query(
                        "SELECT chat_id, text, revision FROM chat_drafts WHERE chat_id = ANY($1)",
                        [[root.chat.id, middle.chat.id]]
                      ) ==
                        [[root.chat.id, "Roll back this draft", 2]]

               Repo.rollback(:rollback_check)
             end)

    assert database_snapshot(actor) == before
    assert_raise RuntimeError, ~r/irreversible/, &Migration.down/0
  end

  test "valid tool anchors merge without erasing the original handoff result trace", %{
    actor: actor
  } do
    [root, middle, terminal] = family(actor, [:input, :modern])
    call = create_item!(actor, root.reply_step, sequence: 2, type: :tool_call)

    result =
      create_item!(actor, root.reply_step,
        sequence: 3,
        type: :tool_result,
        tool_call_item_id: call.id
      )

    content =
      create_content!(actor, result,
        kind: :opaque,
        content_json: %{
          "raw" => %{
            "handoff" => %{
              "chat_id" => middle.chat.id,
              "generation_message_id" => middle.reply.id
            }
          }
        }
      )

    Repo.query!("UPDATE chats SET parent_tool_call_item_id = $1 WHERE id = $2", [
      call.id,
      middle.chat.id
    ])

    original =
      query("SELECT to_jsonb(c) FROM chat_message_contents c WHERE id = $1", [content.id])

    assert {:ok, :ok} = Migration.migrate(Repo)

    assert query("SELECT to_jsonb(c) FROM chat_message_contents c WHERE id = $1", [content.id]) ==
             original

    assert query("SELECT last_message_id FROM chats WHERE id = $1", [root.chat.id]) == [
             [terminal.reply.id]
           ]

    assert query(
             "SELECT sum(cost), sum(cached_input_tokens) FROM chat_message_steps s JOIN chat_messages m ON m.id = s.chat_message_id WHERE m.chat_id = $1",
             [root.chat.id]
           ) == [[1.5, Decimal.new(9)]]
  end

  test "unknown cascading references abort after transfers and roll all of them back", %{
    actor: actor
  } do
    [root, middle, terminal] = family(actor, [:input, :handoff_context])

    Repo.query!(
      "CREATE TABLE migration_extra_dependency (chat_id bigint REFERENCES chats(id) ON DELETE CASCADE)"
    )

    Repo.query!("INSERT INTO migration_extra_dependency VALUES ($1)", [terminal.chat.id])

    assert {:ok, %{conflict: false}} =
             ChatDraft.save(
               terminal.chat.id,
               %{"text" => "Preserve before FK guard", "expected_revision" => 0},
               actor
             )

    before = database_snapshot(actor)

    assert_raise RuntimeError, ~r/unmigrated dependency .*migration_extra_dependency/, fn ->
      Migration.migrate(Repo)
    end

    assert database_snapshot(actor) == before

    assert query("SELECT chat_id FROM migration_extra_dependency WHERE chat_id = $1", [
             terminal.chat.id
           ]) == [[terminal.chat.id]]

    Repo.query!("DROP TABLE migration_extra_dependency")
    assert {:ok, :ok} = Migration.migrate(Repo)

    assert {:ok, %{text: "Preserve before FK guard", revision: 2}} =
             ChatDraft.get(root.chat.id, actor)

    assert query("SELECT id FROM chats WHERE id = ANY($1)", [[middle.chat.id, terminal.chat.id]]) ==
             []

    assert query("SELECT id FROM chats WHERE id = $1", [root.chat.id]) == [[root.chat.id]]
  end

  test "invalid trace ownership, cross-chat message links and active uploads keep families separate",
       %{actor: actor} do
    %{user: other} = user_fixture()

    for hazard <- [:message_owner, :content_owner, :cross_chat, :upload, :wrong_tool_anchor] do
      [root, child] = family(actor, [:input])

      case hazard do
        :message_owner ->
          Repo.query!("UPDATE chat_messages SET owner_id = $1 WHERE id = $2", [
            other.id,
            child.first.id
          ])

        :content_owner ->
          Repo.query!(
            "UPDATE chat_message_contents SET owner_id = $1 WHERE chat_message_item_id = $2",
            [other.id, child.summary.id]
          )

        :cross_chat ->
          outside = create_empty_chat!(actor)
          external = create_message!(actor, outside)

          Repo.query!("UPDATE chat_messages SET parent_id = $1 WHERE id = $2", [
            child.reply.id,
            external.id
          ])

        :upload ->
          create!(
            ChatUploadSession,
            :start,
            %{
              chat_id: child.chat.id,
              filename: "pending.txt",
              mime_type: "text/plain",
              size_bytes: 3,
              chunk_size_bytes: 3,
              expires_at: DateTime.add(DateTime.utc_now(), 3600)
            },
            actor
          )

        :wrong_tool_anchor ->
          Repo.query!("UPDATE chats SET parent_tool_call_item_id = $1 WHERE id = $2", [
            root.summary.id,
            child.chat.id
          ])
      end

      before =
        query(
          "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
          [actor.id]
        )

      assert {:ok, :ok} = Migration.migrate(Repo)

      assert query(
               "SELECT id, chat_id, parent_id FROM chat_messages WHERE owner_id = $1 ORDER BY id",
               [actor.id]
             ) == before

      assert query("SELECT id FROM chats WHERE id = $1", [child.chat.id]) == [[child.chat.id]]
    end
  end

  defp family(actor, modes, opts \\ []) do
    root = segment(actor, :input, opts)
    children = Enum.map(modes, &segment(actor, &1, Keyword.delete(opts, :root)))
    chain = [root | children]
    for {parent, child} <- Enum.zip(chain, children), do: legacy_link(child, parent)
    chain
  end

  defp segment(actor, mode, opts \\ []) do
    chat =
      Keyword.get_lazy(opts, :root, fn ->
        create_empty_chat!(
          actor,
          Map.put(
            Keyword.get(opts, :chat_attrs, %{}),
            :subagent,
            Keyword.get(opts, :subagent, false)
          )
        )
      end)

    first = create_message!(actor, chat, role: :user)
    first_step = create_step!(actor, first)

    summary =
      case mode do
        :modern ->
          create_item!(actor, first_step, type: :handoff_history)
          create_text_item!(actor, first_step, "Summary", sequence: 2, type: :handoff_message)

        mode ->
          item = create_text_item!(actor, first_step, "Summary", type: :input)

          if mode == :handoff_context,
            do:
              Repo.query!(
                "UPDATE chat_message_items SET type = 'handoff_context' WHERE id = $1",
                [item.id]
              )

          item
      end

    reply = create_message!(actor, chat, parent_id: first.id)
    reply_step = create_step!(actor, reply, cost: 0.5, input_tokens: 10, cached_input_tokens: 3)
    create_text_item!(actor, reply_step, "Historical assistant trace")

    chat
    |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: reply.id}, actor: actor)
    |> Ash.update!(actor: actor)

    %{
      chat: chat,
      first: first,
      first_step: first_step,
      summary: summary,
      reply: reply,
      reply_step: reply_step
    }
  end

  # Only SQL can represent the enum/link values removed from the current Ash API.
  defp legacy_link(child, parent) do
    Repo.query!(
      "UPDATE chats SET parent_relation_kind = 'handoff', parent_chat_id = $1, parent_message_id = $2 WHERE id = $3",
      [parent.chat.id, parent.reply.id, child.chat.id]
    )
  end

  defp update_chat(actor, chat, attrs),
    do:
      chat |> Ash.Changeset.for_update(:update, attrs, actor: actor) |> Ash.update!(actor: actor)

  # No public action can seed arbitrary historical per-chat revision clocks.
  defp revision(segment, value, actor, read, manual \\ false) do
    Repo.query!("UPDATE chat_activities SET revision = $1 WHERE chat_id = $2", [
      value,
      segment.chat.id
    ])

    Repo.query!(
      "INSERT INTO chat_read_states (chat_id, user_id, read_revision, manual_unread, state_version) VALUES ($1, $2, $3, $4, 1)",
      [segment.chat.id, actor.id, read, manual]
    )
  end

  defp items(message_id),
    do:
      query(
        "SELECT i.id, i.type, i.sequence FROM chat_message_items i JOIN chat_message_steps s ON s.id = i.chat_message_step_id WHERE s.chat_message_id = $1 ORDER BY s.sequence, i.sequence",
        [message_id]
      )

  defp query(sql, params), do: Repo.query!(sql, params).rows

  defp table_rows(table, actor) do
    scope =
      cond do
        table in ~w(chat_activities chat_read_states chat_drafts chat_shares) ->
          "t.chat_id IN (SELECT id FROM chats WHERE owner_id = $1)"

        table == "llm_usage_records" ->
          "t.usage_user_id_snapshot = $1"

        true ->
          "t.owner_id = $1"
      end

    query("SELECT to_jsonb(t) FROM #{table} t WHERE #{scope} ORDER BY to_jsonb(t)::text", [
      actor.id
    ])
    |> List.flatten()
  end

  defp database_snapshot(actor),
    do:
      Map.new(
        ~w(chats chat_messages chat_message_steps chat_message_items chat_message_contents
          chat_activities chat_read_states chat_drafts chat_shares chat_tool_bindings
          chat_knowledge_blocks background_tasks chat_queued_messages chat_queued_message_contents
          chat_upload_sessions llm_usage_records),
        &{&1, table_rows(&1, actor)}
      )
end
