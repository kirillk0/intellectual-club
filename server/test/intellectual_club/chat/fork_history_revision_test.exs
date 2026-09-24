defmodule IntellectualClub.Chat.ForkHistoryRevisionTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatShare
  alias IntellectualClub.Chat.ForkHistory
  alias IntellectualClub.Chat.ForkHistoryCorruptFixture
  alias IntellectualClub.Chat.ForkHistoryFixtureDomain
  alias IntellectualClub.Chat.ForkHistoryRevision
  alias IntellectualClub.Files.File, as: MediaFile
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  @sql_event [:intellectual_club, :repo, :query]
  @task "Inspect this branch only.  "

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor}
  end

  test "stable binary revision, private action and fresh supplied Chat anchors", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)
    assert original =~ ~r/^fhr1:[0-9a-f]{64}$/
    assert revision(child.id, actor) == original
    assert revision(%{child | fork_task: "forged", fork_source_step_id: nil}, actor) == original
    refute Ash.Resource.Info.action(ForkHistoryRevision, :revision).public?

    corrupt_anchor!(child, %{fork_task: "A fresh task"}, actor)
    refute revision(child, actor) == original
    assert revision(child, actor) == revision(child.id, actor)

    assert {:error, _} =
             ForkHistoryRevision
             |> Ash.ActionInput.for_action(:revision, %{chat_id: child.id})
             |> Ash.run_action(authorize?: true)
  end

  test "nil means a freshly authorized ordinary or legacy copied chat", %{actor: actor} do
    source = source!(actor)
    assert revision(source.chat, actor) == nil

    legacy =
      chat!(
        Map.drop(link_attrs(source), [:fork_source_step_id, :fork_task]),
        actor
      )

    assert revision(legacy, actor) == nil
    corrupt_anchor!(legacy, %{fork_task: @task}, actor)
    assert is_binary(revision(legacy, actor))
    assert is_binary(revision(legacy.id, actor))
  end

  test "unexpected metadata read failures use retry tokens and recover", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)
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

  test "content-only text edits invalidate without changing any parent timestamps", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)
    parents = [source.chat, source.root, source.root_step, source.root_item]
    timestamps = Enum.map(parents, &timestamp(&1, actor))

    update!(source.root_content, %{content_text: "Changed root text"}, actor)
    refute revision(child, actor) == original
    assert Enum.map(parents, &timestamp(&1, actor)) == timestamps
  end

  test "tool call payload validity is separate, but edits, deletion and restoration invalidate",
       %{
         actor: actor
       } do
    source = source!(actor)
    child = child!(source, actor)
    valid = revision(child, actor)
    assert {:ok, _} = ForkHistory.prefix(child, actor)

    broken = update!(source.call_content, %{content_json: %{"malformed" => true}}, actor)
    invalid = revision(child, actor)
    refute invalid == valid
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(child, actor)
    assert revision(child, actor) == invalid

    Ash.destroy!(broken, actor: actor)
    missing = revision(child, actor)
    refute missing == invalid
    content!(source.call, 2, :opaque, %{content_json: call_payload()}, actor)
    refute revision(child, actor) in [valid, invalid, missing]
    assert {:ok, _} = ForkHistory.prefix(child, actor)
  end

  test "delete and same-count replacement invalidate even with unchanged maximum timestamp", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)

    old =
      source.answer
      |> content!(10, :text, %{content_text: "Replace me"}, actor)
      |> force_update!(%{updated_at: ~U[2000-01-01 00:00:00.000000Z]}, actor)

    source.answer
    |> content!(11, :text, %{content_text: "Maximum timestamp"}, actor)
    |> force_update!(%{updated_at: ~U[2100-01-01 00:00:00.000000Z]}, actor)

    before = content_count_and_max(source.answer, actor)
    original = revision(child, actor)
    Ash.destroy!(old, actor: actor)
    deleted = revision(child, actor)
    refute deleted == original

    source.answer
    |> content!(10, :text, %{content_text: "Replace me"}, actor)
    |> force_update!(%{updated_at: old.updated_at}, actor)

    assert content_count_and_max(source.answer, actor) == before
    refute revision(child, actor) in [original, deleted]
  end

  test "empty step and item replacement cannot hide behind unchanged counts or timestamps", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    old_time = ~U[2000-01-01 00:00:00.000000Z]
    empty_step = step!(source.root, 2, actor)
    original = revision(child, actor)
    Ash.destroy!(empty_step, actor: actor)
    deleted = revision(child, actor)
    refute deleted == original
    step!(source.root, 2, actor)
    refute revision(child, actor) in [original, deleted]

    attrs = %{chat_message_step_id: source.step.id, sequence: 30, type: :reasoning}

    empty_item =
      ChatMessageItem
      |> create!(:create, attrs, actor)
      |> force_update!(%{created_at: old_time, updated_at: old_time}, actor)

    original = revision(child, actor)
    Ash.destroy!(empty_item, actor: actor)
    deleted = revision(child, actor)
    refute deleted == original

    ChatMessageItem
    |> create!(:create, attrs, actor)
    |> force_update!(%{created_at: old_time, updated_at: old_time}, actor)

    refute revision(child, actor) in [original, deleted]
  end

  test "message parents and role, step sequence and parent are represented without timestamps", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)

    moved = force_update!(source.message, %{parent_id: nil}, actor, :set_generation_state)
    refute revision(child, actor) == original
    moved = force_update!(moved, %{parent_id: source.root.id}, actor, :set_generation_state)
    assert revision(child, actor) == original
    moved = force_update!(moved, %{role: :user}, actor, :set_generation_state)
    refute revision(child, actor) == original
    force_update!(moved, %{role: :assistant}, actor, :set_generation_state)
    assert revision(child, actor) == original

    moved_step = force_update!(source.previous, %{sequence: 3}, actor)
    refute revision(child, actor) == original
    moved_step = force_update!(moved_step, %{sequence: 1}, actor)
    assert revision(child, actor) == original
    moved_step = force_update!(moved_step, %{chat_message_id: source.root.id, sequence: 7}, actor)
    refute revision(child, actor) == original
    force_update!(moved_step, %{chat_message_id: source.message.id, sequence: 1}, actor)
    assert revision(child, actor) == original
  end

  test "item and content metadata detect sequence and reparent changes with frozen timestamps", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)

    changed =
      force_update!(source.answer, %{sequence: 19, updated_at: source.answer.updated_at}, actor)

    refute revision(child, actor) == original

    changed =
      force_update!(changed, %{sequence: 10, updated_at: source.answer.updated_at}, actor)

    assert revision(child, actor) == original

    force_update!(
      changed,
      %{chat_message_step_id: source.previous.id, sequence: 19, updated_at: changed.updated_at},
      actor
    )

    moved = revision(child, actor)
    refute moved == original
    text = source.root_content
    force_update!(text, %{sequence: 3, updated_at: text.updated_at}, actor)
    refute revision(child, actor) == moved
  end

  test "nested source edits invalidate descendants, but a child's unrelated local tail does not",
       %{
         actor: actor
       } do
    outer = source!(actor)
    child = child!(outer, actor)
    inner = source!(actor, chat: child)
    grandchild = child!(inner, actor)
    child_revision = revision(child, actor)
    grandchild_revision = revision(grandchild, actor)

    update!(inner.root_content, %{content_text: "Inner edit"}, actor)
    assert revision(child, actor) == child_revision
    refute revision(grandchild, actor) == grandchild_revision
    inner_edit = revision(grandchild, actor)
    update!(outer.root_content, %{content_text: "Outer edit"}, actor)
    refute revision(child, actor) == child_revision
    refute revision(grandchild, actor) == inner_edit
  end

  test "future steps, messages, siblings, active leaf and execution metadata are excluded", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)
    later = step!(source.message, 3, actor)
    item!(later, 1, :answer, "Later step", actor)
    later_message = message!(source.chat, :user, source.message.id, actor)
    item!(step!(later_message, 1, actor), 1, :input, "Later message", actor)
    sibling = message!(source.chat, :assistant, source.root.id, actor)
    item!(step!(sibling, 1, actor), 1, :answer, "Sibling branch", actor)
    assert Ash.get!(Chat, source.chat.id, actor: actor).last_message_id == sibling.id
    assert revision(child, actor) == original

    for status <- [:generating, :canceled, :error, :done] do
      update!(
        source.message,
        %{status: status, error_detail: "Not history"},
        actor,
        :set_generation_state
      )
    end

    for status <- [:waiting_tools, :canceled, :error, :done] do
      update!(
        source.step,
        %{
          status: status,
          input_tokens: 999,
          output_tokens: 111,
          cost: 1.5,
          raw_request: %{"private" => "changed request"},
          raw_response: %{"private" => "changed response"}
        },
        actor
      )

      assert revision(child, actor) == original
    end

    update!(source.previous, %{response_final: false, status: :error}, actor)
    update!(source.chat, %{note: "Unrelated note"}, actor)
    update!(child, %{note: "Not the task"}, actor)
    assert revision(child, actor) == original
    update!(source.step, %{response_final: false}, actor)
    refute revision(child, actor) == original
    update!(source.step, %{response_final: true}, actor)
    assert revision(child, actor) == original
  end

  test "boundary results, artifacts, errors and post-response steering never invalidate", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)

    for {type, sequence} <- Enum.with_index([:tool_result, :artifact, :error, :steering], 30) do
      item =
        item!(
          source.step,
          sequence,
          type,
          "Excluded",
          actor,
          %{"placement" => "after_response"},
          source.call.id
        )

      assert revision(child, actor) == original
      update!(hd(item.contents), %{content_text: "Still excluded"}, actor)
      assert revision(child, actor) == original
      Ash.destroy!(item, actor: actor)
      assert revision(child, actor) == original
    end

    item!(source.previous, 30, :error, "Included on an earlier step", actor)
    refute revision(child, actor) == original
  end

  test "boundary steering uses the first ordered opaque content with a valid placement", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)
    steering = item!(source.step, 30, :steering, "Steering text", actor)
    content!(steering, 2, :opaque, %{content_json: %{"placement" => "invalid"}}, actor)
    content!(steering, 3, :text, %{content_json: %{"placement" => "before_response"}}, actor)

    first =
      content!(steering, 10, :opaque, %{content_json: %{"placement" => "after_response"}}, actor)

    content!(steering, 20, :opaque, %{content_json: %{"placement" => "before_response"}}, actor)
    assert revision(child, actor) == original
    update!(hd(steering.contents), %{content_text: "Ignored text edit"}, actor)
    assert revision(child, actor) == original
    assert {:ok, [_, boundary]} = ForkHistory.prefix(child, actor)
    refute Enum.any?(List.last(boundary.steps).items, &(&1.id == steering.id))

    before = update!(first, %{content_json: %{"placement" => "before_response"}}, actor)
    included = revision(child, actor)
    refute included == original
    assert {:ok, [_, boundary]} = ForkHistory.prefix(child, actor)
    assert Enum.any?(List.last(boundary.steps).items, &(&1.id == steering.id))
    update!(hd(steering.contents), %{content_text: "Included text edit"}, actor)
    refute revision(child, actor) == included
    after_response = update!(before, %{content_json: %{"placement" => "after_response"}}, actor)
    assert revision(child, actor) == original
    Ash.destroy!(after_response, actor: actor)
    refute revision(child, actor) == original
  end

  test "message cycles and dangling same-chat paths fail closed and terminate", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)

    cycle =
      force_update!(source.root, %{parent_id: source.message.id}, actor, :set_generation_state)

    cyclic = revision(child, actor)
    refute cyclic == original
    assert revision(child, actor) == cyclic
    root = force_update!(cycle, %{parent_id: nil}, actor, :set_generation_state)
    assert revision(child, actor) == original

    other_chat = chat!(%{}, actor)
    other = message!(other_chat, :user, nil, actor)
    dangling = force_update!(root, %{parent_id: other.id}, actor, :set_generation_state)
    refute revision(child, actor) == original
    force_update!(dangling, %{parent_id: nil}, actor, :set_generation_state)
    assert revision(child, actor) == original
  end

  test "SQL availability rejects cycles, dangling branches, non-assistant and foreign-chat anchors",
       %{
         actor: actor
       } do
    source = source!(actor)
    child = child!(source, actor)
    other = source!(actor)

    for parent_id <- [source.message.id, other.root.id] do
      root = force_update!(source.root, %{parent_id: parent_id}, actor, :set_generation_state)
      assert_unavailable_summary(child, actor)
      force_update!(root, %{parent_id: nil}, actor, :set_generation_state)
    end

    boundary = force_update!(source.message, %{role: :user}, actor, :set_generation_state)
    assert_unavailable_summary(child, actor)
    force_update!(boundary, %{role: :assistant}, actor, :set_generation_state)
    corrupt_anchor!(child, %{parent_chat_id: other.chat.id}, actor)
    assert_unavailable_summary(child, actor)
    corrupt_anchor!(child, link_attrs(source), actor)
    update!(source.step, %{response_final: false}, actor)
    assert_unavailable_summary(child, actor)
  end

  test "chat cycles, missing anchors and mismatched structural anchors fail closed", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)

    for attrs <- [
          %{parent_chat_id: nil},
          %{parent_message_id: source.root.id},
          %{parent_tool_call_item_id: source.answer.id},
          %{fork_source_step_id: nil},
          %{fork_task: nil}
        ] do
      corrupt_anchor!(child, attrs, actor)
      refute revision(child, actor) == original
      corrupt_anchor!(child, link_attrs(source), actor)
      assert revision(child, actor) == original
    end

    inner = source!(actor, chat: child)
    corrupt_anchor!(source.chat, link_attrs(inner), actor)
    cyclic = revision(child, actor)
    refute cyclic == original
    assert revision(child, actor) == cyclic
  end

  test "missing actors, unreadable children and forged structs cannot confer access", %{
    actor: actor
  } do
    %{user: stranger} = user_fixture()
    source = source!(actor)
    child = child!(source, actor)
    unavailable = revision(-1, actor)
    assert is_binary(unavailable)
    assert revision(child, nil) == unavailable
    assert revision(child, %{}) == unavailable
    assert revision(%{child | owner_id: stranger.id}, stranger) == unavailable
    assert revision(source.chat, stranger) == unavailable
    assert revision(Integer.pow(10, 100), actor) == unavailable
  end

  test "sharing only a child never grants source access, and revocation invalidates", %{
    actor: actor
  } do
    %{user: reader} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [actor, reader]})
    source = source!(actor, chat_attrs: shareable_attrs!(actor))
    child = child!(source, actor)
    share!(child, group, actor)
    unavailable = revision(child, reader)
    assert is_binary(unavailable)
    refute unavailable == revision(child, actor)
    update!(source.root_content, %{content_text: "Private edit"}, actor)
    assert revision(child, reader) == unavailable

    share = share!(source.chat, group, actor)
    available = revision(child, reader)
    refute available == unavailable
    update!(source.root_content, %{content_text: "Shared edit"}, actor)
    refute revision(child, reader) == available
    Ash.destroy!(share, actor: actor)
    assert revision(child, reader) == unavailable
  end

  test "all entity subqueries honor the actor, including an unreadable ancestor message", %{
    actor: actor
  } do
    %{user: stranger} = user_fixture()
    source = source!(actor)
    child = child!(source, actor)
    original = revision(child, actor)

    for {record, action} <- [
          {source.root, :set_generation_state},
          {source.step, :update},
          {source.root_item, :update},
          {source.root_content, :update}
        ] do
      hidden =
        force_update!(
          record,
          %{owner_id: stranger.id, updated_at: record.updated_at},
          actor,
          action
        )

      refute revision(child, actor) == original

      force_update!(
        hidden,
        %{owner_id: actor.id, updated_at: record.updated_at},
        stranger,
        action
      )

      assert revision(child, actor) == original
    end
  end

  test "file metadata participates even though Files have no updated_at", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)

    file =
      create!(
        MediaFile,
        :create,
        %{
          sha256: String.duplicate("a", 64),
          filename: "one.png",
          mime_type: "image/png",
          size_bytes: 7
        },
        actor
      )

    media = content!(source.answer, 10, :media, %{file_id: file.id}, actor)
    original = revision(child, actor)
    stamp = timestamp(media, actor)

    Enum.reduce(
      [
        %{filename: "two.png"},
        %{mime_type: "image/jpeg"},
        %{size_bytes: 8},
        %{external_id: Ash.UUID.generate()}
      ],
      {file, original},
      fn attrs, {file, previous} ->
        file = force_update!(file, attrs, actor, :update_storage_backend)
        current = revision(child, actor)
        refute current == previous
        assert timestamp(media, actor) == stamp
        {file, current}
      end
    )

    before_missing = revision(child, actor)
    update!(media, %{file_id: nil}, actor)
    refute revision(child, actor) == before_missing
  end

  test "SQL returns only bounded metadata, never text, opaque payloads or step raw data", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    large_payload = String.duplicate("PRIVATE_HISTORY_PAYLOAD", 25_000)
    update!(source.root_content, %{content_text: large_payload}, actor)

    update!(
      source.call_content,
      %{content_json: %{"name" => "agent__fork", "private" => large_payload}},
      actor
    )

    update!(
      source.step,
      %{raw_request: %{"private" => large_payload}, raw_response: %{"private" => large_payload}},
      actor
    )

    {_revision, queries} = measure(fn -> revision(child, actor) end)
    assert length(queries) == 3
    assert Enum.count(queries, &String.starts_with?(&1.sql, "WITH RECURSIVE")) == 1

    for query <- queries do
      assert query.rows <= 1
      assert query.result_bytes < 4096
      refute query.sql =~ ~r/"(?:content_text|raw_request|raw_response)"/
      refute query.result_text =~ "PRIVATE_HISTORY_PAYLOAD"
    end

    [aggregate] = Enum.filter(queries, &String.starts_with?(&1.sql, "WITH RECURSIVE"))
    assert aggregate.rows == 1
    assert aggregate.result_bytes < 1024
    assert aggregate.sql =~ "UNION ("
    refute aggregate.sql =~ "UNION ALL"
    assert aggregate.sql =~ "->> 'placement'"
    assert aggregate.columns == ["available", "digest"]
    assert aggregate.result_text =~ "[[true,"
    refute Regex.match?(~r/"content_json"(?! ->> 'placement')/, aggregate.sql)
  end

  test "SQL round trips and result size do not grow with the number of history messages", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    {original, small} = measure(fn -> revision(child, actor) end)

    parent =
      Enum.reduce(1..12, nil, fn number, parent ->
        message = message!(source.chat, :user, parent, actor)
        item!(step!(message, 1, actor), 1, :input, "Ancestor #{number}", actor)
        message.id
      end)

    force_update!(source.root, %{parent_id: parent}, actor, :set_generation_state)
    {changed, large} = measure(fn -> revision(child, actor) end)
    refute changed == original
    assert length(large) == length(small)
    assert Enum.map(large, & &1.rows) == Enum.map(small, & &1.rows)
    assert Enum.map(large, & &1.result_bytes) == Enum.map(small, & &1.result_bytes)
  end

  test "source traversal is limited to 32 and invalidates when the deep anchor is repaired", %{
    actor: actor
  } do
    root = chat!(%{}, actor)

    {last, previous} =
      Enum.reduce(1..33, {root, nil}, fn _, {chat, _} ->
        message = message!(chat, :assistant, nil, actor)
        step = step!(message, 1, actor)
        call = item!(step, 1, :tool_call, "Call", actor, call_payload())
        source = %{chat: chat, message: message, step: step, call: call}
        {child!(source, actor), chat}
      end)

    {too_deep, queries} = measure(fn -> revision(last, actor) end)
    assert is_binary(too_deep)
    assert Enum.count(queries, &String.starts_with?(&1.sql, "WITH RECURSIVE")) == 32
    corrupt_anchor!(previous, %{fork_source_step_id: nil, fork_task: nil}, actor)
    refute revision(last, actor) == too_deep
  end

  defp revision(chat, actor), do: ForkHistoryRevision.revision(chat, actor)

  defp source!(actor, opts \\ []) do
    chat =
      Keyword.get_lazy(opts, :chat, fn -> chat!(Keyword.get(opts, :chat_attrs, %{}), actor) end)

    root = message!(chat, :user, nil, actor)
    root_step = step!(root, 1, actor)
    root_item = item!(root_step, 1, :input, "Root question", actor)
    message = message!(chat, :assistant, root.id, actor)
    previous = step!(message, 1, actor)
    item!(previous, 1, :answer, "Previous response", actor)
    step = step!(message, 2, actor)
    answer = item!(step, 10, :answer, "Boundary response", actor)
    call = item!(step, 20, :tool_call, "Fork call", actor, call_payload())

    %{
      chat: chat,
      root: root,
      root_step: root_step,
      root_item: root_item,
      root_content: hd(root_item.contents),
      message: message,
      previous: previous,
      step: step,
      answer: answer,
      call: call,
      call_content: Enum.find(call.contents, &(&1.kind == :opaque))
    }
  end

  defp call_payload,
    do: %{"name" => "agent__fork", "call_id" => "fork", "arguments" => %{"task" => @task}}

  defp child!(source, actor) do
    chat!(
      Map.merge(link_attrs(source), %{
        bot_id: source.chat.bot_id,
        llm_configuration_id: source.chat.llm_configuration_id
      }),
      actor
    )
  end

  defp link_attrs(source) do
    %{
      parent_chat_id: source.chat.id,
      parent_message_id: source.message.id,
      parent_tool_call_item_id: source.call.id,
      fork_source_step_id: source.step.id,
      fork_task: @task,
      parent_relation_kind: :fork,
      subagent: true
    }
  end

  defp chat!(attrs, actor) do
    {internal, public} = Map.split(attrs, [:fork_source_step_id, :fork_task])

    Chat
    |> Ash.Changeset.for_create(:create_empty, public, actor: actor)
    |> Ash.Changeset.force_change_attributes(internal)
    |> Ash.create!(actor: actor)
  end

  defp message!(chat, role, parent_id, actor) do
    create!(
      ChatMessage,
      :add_message,
      %{chat_id: chat.id, role: role, parent_id: parent_id, status: :done},
      actor
    )
  end

  defp step!(message, sequence, actor) do
    create!(
      ChatMessageStep,
      :create,
      %{chat_message_id: message.id, sequence: sequence, status: :done, response_final: true},
      actor
    )
  end

  defp item!(step, sequence, type, text, actor, opaque \\ nil, call_id \\ nil) do
    item =
      create!(
        ChatMessageItem,
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: sequence,
          type: type,
          tool_call_item_id: if(type == :tool_result, do: call_id)
        },
        actor
      )

    content!(item, 1, :text, %{content_text: text}, actor)
    if opaque, do: content!(item, 2, :opaque, %{content_json: opaque}, actor)
    Ash.load!(item, [:contents], actor: actor)
  end

  defp content!(item, sequence, kind, attrs, actor) do
    create!(
      ChatMessageContent,
      :create,
      Map.merge(
        %{
          chat_message_item_id: item.id,
          sequence: sequence,
          kind: kind
        },
        attrs
      ),
      actor
    )
  end

  defp content_count_and_max(item, actor) do
    contents = Ash.load!(item, [:contents], actor: actor).contents
    {length(contents), contents |> Enum.map(& &1.updated_at) |> Enum.max(DateTime)}
  end

  defp timestamp(%resource{id: id}, actor), do: Ash.get!(resource, id, actor: actor).updated_at

  defp corrupt_anchor!(chat, attrs, actor) do
    ForkHistoryCorruptFixture
    |> Ash.get!(chat.id, actor: actor, domain: ForkHistoryFixtureDomain)
    |> Ash.Changeset.for_update(:corrupt_anchor, attrs, actor: actor)
    |> Ash.update!(actor: actor, domain: ForkHistoryFixtureDomain)
  end

  # Force changes through authorized Ash actions only, to model legacy corruption
  # and metadata edits which the public write API does not normally expose.
  defp force_update!(record, attrs, actor, action \\ :update) do
    record
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.Changeset.force_change_attributes(attrs)
    |> Ash.update!(actor: actor)
  end

  defp update!(%resource{id: id}, attrs, actor, action \\ :update) do
    resource
    |> Ash.get!(id, actor: actor)
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp create!(resource, action, attrs, actor) do
    resource |> Ash.Changeset.for_create(action, attrs, actor: actor) |> Ash.create!(actor: actor)
  end

  defp shareable_attrs!(actor) do
    provider =
      create!(
        LlmProvider,
        :create,
        %{
          name: "Revision test",
          type: :responses,
          base_url: "https://example.invalid/v1",
          api_key: "test"
        },
        actor
      )

    configuration =
      create!(
        LlmConfiguration,
        :create,
        %{
          provider_id: provider.id,
          model_name: "test",
          parameters: %{},
          enabled: true
        },
        actor
      )

    bot = create!(Bot, :create, %{name: "Revision test", first_messages: []}, actor)
    %{bot_id: bot.id, llm_configuration_id: configuration.id}
  end

  defp share!(chat, group, actor) do
    create!(
      ChatShare,
      :create,
      %{
        chat_id: chat.id,
        user_group_id: group.id,
        bot_id: chat.bot_id,
        llm_configuration_id: chat.llm_configuration_id
      },
      actor
    )
  end

  defp assert_unavailable_summary(chat, actor) do
    {revision, queries} = measure(fn -> revision(chat, actor) end)
    assert is_binary(revision)
    [aggregate] = Enum.filter(queries, &String.starts_with?(&1.sql, "WITH RECURSIVE"))
    assert aggregate.rows == 1
    assert aggregate.result_text =~ "[[false,"
  end

  defp measure(operation) do
    table = :ets.new(__MODULE__, [:ordered_set, :public])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, @sql_event, &__MODULE__.handle_query/4, %{
        root: self(),
        table: table
      })

    try do
      result = operation.()
      {result, Enum.map(:ets.tab2list(table), &elem(&1, 1))}
    after
      :telemetry.detach(handler)
      :ets.delete(table)
    end
  end

  @doc false
  def handle_query(_event, _measurements, metadata, %{root: root, table: table}) do
    if self() == root or root in Process.get(:"$callers", []) or metadata[:caller] == root do
      sql = IO.iodata_to_binary(metadata.query)

      if String.starts_with?(sql, ["SELECT", "WITH RECURSIVE"]) do
        {rows, bytes, text, columns} =
          case metadata.result do
            {:ok, %{rows: rows, columns: columns}} ->
              {length(rows || []), :erlang.external_size(rows), inspect(rows), columns}

            result ->
              {0, :erlang.external_size(result), inspect(result), []}
          end

        :ets.insert(
          table,
          {System.unique_integer([:positive, :monotonic]),
           %{
             sql: sql,
             rows: rows,
             result_bytes: bytes,
             result_text: text,
             columns: columns
           }}
        )
      end
    end
  end

  defp retry_bucket, do: div(System.system_time(:second), 60)
end
