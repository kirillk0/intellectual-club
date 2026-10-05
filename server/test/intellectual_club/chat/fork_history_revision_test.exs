defmodule IntellectualClub.Chat.ForkHistoryRevisionTest do
  # Which source changes the linked fork revision detects and which it ignores.
  # Shared fail-closed, access, live-edit and depth scenarios are in ForkHistoryTest.
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Chat.ForkFixtures

  alias IntellectualClub.Chat.{ForkHistory, ForkHistoryRevision}
  alias IntellectualClub.Files.File, as: MediaFile

  @old_time ~U[2000-01-01 00:00:00.000000Z]

  setup do
    %{user: actor} = user_fixture()
    source = create_fork_source!(actor, previous_step?: true)
    %{actor: actor, source: source, child: create_fork_child!(actor, source)}
  end

  test "stable binary revision, private action and fresh supplied Chat anchors", %{
    actor: actor,
    child: child
  } do
    original = revision(child, actor)
    assert original =~ ~r/^fhr1:[0-9a-f]{64}$/
    assert revision(child.id, actor) == original
    assert revision(%{child | fork_task: "forged", fork_source_step_id: nil}, actor) == original
    refute Ash.Resource.Info.action(ForkHistoryRevision, :revision).public?

    corrupt_chat!(actor, child, %{fork_task: "A fresh task"})
    refute revision(child, actor) == original
    assert revision(child, actor) == revision(child.id, actor)

    assert {:error, _} =
             ForkHistoryRevision
             |> Ash.ActionInput.for_action(:revision, %{chat_id: child.id})
             |> Ash.run_action(authorize?: true)
  end

  test "unexpected metadata read failures use retry tokens and recover", %{
    actor: actor,
    child: child
  } do
    healthy = revision(child, actor)
    previous_repo = Repo.put_dynamic_repo(:fork_revision_missing_repo)

    try do
      bucket = retry_bucket()
      {failed, log} = ExUnit.CaptureLog.with_log(fn -> revision(child, actor) end)
      assert log =~ "Linked fork revision for chat #{child.id}"
      assert is_binary(failed)
      refute failed == healthy
      # A persistent failure is acknowledged once per bucket, not on every probe.
      {repeated, _log} = ExUnit.CaptureLog.with_log(fn -> revision(child, actor) end)
      if retry_bucket() == bucket, do: assert(repeated == failed)
    after
      Repo.put_dynamic_repo(previous_repo)
    end

    assert revision(child, actor) == healthy
  end

  test "call payload edits, deletion and re-creation each yield a distinct revision", %{
    actor: actor,
    source: source,
    child: child
  } do
    valid = revision(child, actor)
    broken = update_record!(actor, source.call_content, %{content_json: %{"malformed" => true}})
    invalid = revision(child, actor)
    refute invalid == valid
    assert revision(child, actor) == invalid

    Ash.destroy!(broken, actor: actor)
    missing = revision(child, actor)
    refute missing == invalid

    create_content!(actor, source.call,
      sequence: 2,
      kind: :opaque,
      content_json: fork_call_payload()
    )

    refute revision(child, actor) in [valid, invalid, missing]
    assert {:ok, _} = ForkHistory.prefix(child, actor)
  end

  test "delete and same-count replacement invalidate even with unchanged maximum timestamp", %{
    actor: actor,
    source: source,
    child: child
  } do
    old = create_content!(actor, source.answer, sequence: 10, content_text: "Replace me")
    old = force_update!(actor, old, %{updated_at: @old_time})

    newest =
      create_content!(actor, source.answer, sequence: 11, content_text: "Maximum timestamp")

    force_update!(actor, newest, %{updated_at: ~U[2100-01-01 00:00:00.000000Z]})

    before = content_count_and_max(source.answer, actor)
    original = revision(child, actor)
    Ash.destroy!(old, actor: actor)
    deleted = revision(child, actor)
    refute deleted == original

    replacement = create_content!(actor, source.answer, sequence: 10, content_text: "Replace me")
    force_update!(actor, replacement, %{updated_at: old.updated_at})
    assert content_count_and_max(source.answer, actor) == before
    refute revision(child, actor) in [original, deleted]
  end

  test "empty step and item replacement cannot hide behind unchanged counts or timestamps", %{
    actor: actor,
    source: source,
    child: child
  } do
    empty_step = create_step!(actor, source.root, sequence: 2, response_final: true)
    original = revision(child, actor)
    Ash.destroy!(empty_step, actor: actor)
    deleted = revision(child, actor)
    refute deleted == original
    create_step!(actor, source.root, sequence: 2, response_final: true)
    refute revision(child, actor) in [original, deleted]

    old_item! = fn ->
      item = create_item!(actor, source.step, sequence: 30, type: :reasoning)
      force_update!(actor, item, %{created_at: @old_time, updated_at: @old_time})
    end

    empty_item = old_item!.()
    original = revision(child, actor)
    Ash.destroy!(empty_item, actor: actor)
    deleted = revision(child, actor)
    refute deleted == original
    old_item!.()
    refute revision(child, actor) in [original, deleted]
  end

  test "message parents, step sequence and step parent are represented without timestamps", %{
    actor: actor,
    source: source,
    child: child
  } do
    original = revision(child, actor)

    moved = reparent_message!(actor, source.message, nil)
    refute revision(child, actor) == original
    reparent_message!(actor, moved, source.root.id)
    assert revision(child, actor) == original

    moved_step = force_update!(actor, source.previous, %{sequence: 3})
    refute revision(child, actor) == original
    moved_step = force_update!(actor, moved_step, %{sequence: 1})
    assert revision(child, actor) == original
    moved_step = force_update!(actor, moved_step, %{chat_message_id: source.root.id, sequence: 7})
    refute revision(child, actor) == original
    force_update!(actor, moved_step, %{chat_message_id: source.message.id, sequence: 1})
    assert revision(child, actor) == original
  end

  test "item and content metadata detect sequence and reparent changes with frozen timestamps", %{
    actor: actor,
    source: source,
    child: child
  } do
    original = revision(child, actor)
    frozen = source.answer.updated_at

    changed = force_update!(actor, source.answer, %{sequence: 19, updated_at: frozen})
    refute revision(child, actor) == original
    changed = force_update!(actor, changed, %{sequence: 10, updated_at: frozen})
    assert revision(child, actor) == original

    force_update!(actor, changed, %{
      chat_message_step_id: source.previous.id,
      sequence: 19,
      updated_at: changed.updated_at
    })

    moved = revision(child, actor)
    refute moved == original
    text = source.root_content
    force_update!(actor, text, %{sequence: 3, updated_at: text.updated_at})
    refute revision(child, actor) == moved
  end

  test "boundary results, artifacts, errors and post-response steering never invalidate", %{
    actor: actor,
    source: source,
    child: child
  } do
    original = revision(child, actor)

    for {type, sequence} <- Enum.with_index([:tool_result, :artifact, :error, :steering], 30) do
      item =
        create_opaque_item!(actor, source.step, "Excluded", %{"placement" => "after_response"},
          sequence: sequence,
          type: type,
          tool_call_item_id: if(type == :tool_result, do: source.call.id)
        )

      assert revision(child, actor) == original
      update_record!(actor, text_content(item), %{content_text: "Still excluded"})
      assert revision(child, actor) == original
      Ash.destroy!(item, actor: actor)
      assert revision(child, actor) == original
    end

    create_text_item!(actor, source.previous, "Included on an earlier step",
      sequence: 30,
      type: :error
    )

    refute revision(child, actor) == original
  end

  test "boundary steering uses the first ordered opaque content with a valid placement", %{
    actor: actor,
    source: source,
    child: child
  } do
    original = revision(child, actor)
    steering = create_text_item!(actor, source.step, "Steering", sequence: 30, type: :steering)
    placement! = &create_content!(actor, steering, sequence: &1, kind: &2, content_json: &3)
    placement!.(2, :opaque, %{"placement" => "invalid"})
    placement!.(3, :text, %{"placement" => "before_response"})
    first = placement!.(10, :opaque, %{"placement" => "after_response"})
    placement!.(20, :opaque, %{"placement" => "before_response"})
    assert revision(child, actor) == original
    update_record!(actor, text_content(steering), %{content_text: "Ignored text edit"})
    assert revision(child, actor) == original
    assert {:ok, [_, boundary]} = ForkHistory.prefix(child, actor)
    refute Enum.any?(List.last(boundary.steps).items, &(&1.id == steering.id))

    before = update_record!(actor, first, %{content_json: %{"placement" => "before_response"}})
    included = revision(child, actor)
    refute included == original
    assert {:ok, [_, boundary]} = ForkHistory.prefix(child, actor)
    assert Enum.any?(List.last(boundary.steps).items, &(&1.id == steering.id))
    update_record!(actor, text_content(steering), %{content_text: "Included text edit"})
    refute revision(child, actor) == included

    after_response =
      update_record!(actor, before, %{content_json: %{"placement" => "after_response"}})

    assert revision(child, actor) == original
    Ash.destroy!(after_response, actor: actor)
    refute revision(child, actor) == original
  end

  test "all entity subqueries honor the actor, including an unreadable ancestor message", %{
    actor: actor,
    source: source,
    child: child
  } do
    %{user: stranger} = user_fixture()
    original = revision(child, actor)

    for {record, action} <- [
          {source.root, :set_generation_state},
          {source.step, :update},
          {source.root_item, :update},
          {source.root_content, :update}
        ] do
      frozen = record.updated_at
      hidden = force_update!(actor, record, %{owner_id: stranger.id, updated_at: frozen}, action)
      refute revision(child, actor) == original
      force_update!(stranger, hidden, %{owner_id: actor.id, updated_at: frozen}, action)
      assert revision(child, actor) == original
    end
  end

  test "file metadata participates even though Files have no updated_at", %{
    actor: actor,
    source: source,
    child: child
  } do
    file =
      create!(
        MediaFile,
        %{
          sha256: String.duplicate("a", 64),
          filename: "one.png",
          mime_type: "image/png",
          size_bytes: 7
        },
        actor
      )

    media = create_content!(actor, source.answer, sequence: 10, kind: :media, file_id: file.id)
    original = revision(child, actor)
    stamp = updated_at(media, actor)

    Enum.reduce(
      [
        %{filename: "two.png"},
        %{mime_type: "image/jpeg"},
        %{size_bytes: 8},
        %{external_id: Ash.UUID.generate()}
      ],
      {file, original},
      fn attrs, {file, previous} ->
        file = force_update!(actor, file, attrs, :update_storage_backend)
        current = revision(child, actor)
        refute current == previous
        assert updated_at(media, actor) == stamp
        {file, current}
      end
    )

    before_missing = revision(child, actor)
    update_record!(actor, media, %{file_id: nil})
    refute revision(child, actor) == before_missing
  end

  defp revision(chat, actor), do: ForkHistoryRevision.revision(chat, actor)

  defp text_content(item), do: Enum.find(item.contents, &(&1.kind == :text))

  defp content_count_and_max(item, actor) do
    contents = Ash.load!(item, [:contents], actor: actor).contents
    {length(contents), contents |> Enum.map(& &1.updated_at) |> Enum.max(DateTime)}
  end

  defp updated_at(%resource{id: id}, actor), do: Ash.get!(resource, id, actor: actor).updated_at

  defp retry_bucket, do: div(System.system_time(:second), 60)
end
