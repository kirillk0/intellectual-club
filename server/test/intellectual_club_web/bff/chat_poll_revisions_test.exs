defmodule IntellectualClubWeb.Bff.ChatPollRevisionsTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageContent,
    ChatMessageStep,
    SubchatCostCache,
    Threads
  }

  alias IntellectualClub.Generation.LegacyGenerationSnapshotStub
  alias IntellectualClubWeb.Bff.PollCache

  setup do
    for child <- [PollCache, SubchatCostCache] do
      if is_nil(Process.whereis(child)), do: start_supervised!(child)
    end

    :ok
  end

  test "unchanged polls return 204 before completed content loads; partial replies omit details",
       %{conn: conn} do
    {conn, actor, _chat, message} = fixture(conn)
    first = poll(conn, message.id, %{"working_step_id" => "latest"}) |> json_response(200)
    assert first["content"]["parts"] != []
    assert is_map(first["working_open"]["step"])
    refute Map.has_key?(first["working_open"]["step"], "raw_request")

    params = %{
      "revision" => first["revision"],
      "content_revision" => first["content_revision"],
      "working_step_id" => "latest",
      "working_revision" => first["working_open"]["revision"]
    }

    {unchanged, queries} = measure(fn -> poll(conn, message.id, params) end)
    assert response(unchanged, 204) == ""
    assert_no_content_load(queries)

    # The cache also avoids repeated loads for old clients without revisions.
    {_response, queries} = measure(fn -> poll(conn, message.id) end)
    assert_no_content_load(queries)

    partial = poll(conn, message.id, Map.delete(params, "revision")) |> json_response(200)
    refute Map.has_key?(partial, "content")
    refute Map.has_key?(partial["working_open"], "step")
    assert partial["working_open"]["steps"] == first["working_open"]["steps"]
    assert Ash.get!(ChatMessage, message.id, actor: actor).status == :done
  end

  for protocol <- ["legacy", "cursor"] do
    @protocol protocol
    test "#{protocol} polling reuses cached payloads after user activity changes", %{conn: conn} do
      {conn, actor, _chat, message} = fixture(conn)
      params = %{"working_step_id" => "latest", "poll_protocol" => @protocol}
      first = poll(conn, message.id, params) |> json_response(200)
      assert first["content"]["parts"] != []
      assert is_map(first["working_open"]["step"])

      user =
        IntellectualClub.Accounts.User
        |> Ash.Query.for_read(:get_current, %{id: actor.id})
        |> Ash.read_one!(actor: actor)

      activity_at = DateTime.add(user.last_activity_at, 1, :second)

      user
      |> Ash.Changeset.for_update(:touch_activity, %{last_activity_at: activity_at}, actor: actor)
      |> Ash.update!(actor: actor)

      # Omit client revisions so both display and selected details must use the cache.
      {response, queries} = measure(fn -> poll(conn, message.id, params) end)
      assert response.assigns.current_user.last_activity_at == activity_at
      payload = json_response(response, 200)
      assert payload["content"] == first["content"]
      assert payload["working_open"] == first["working_open"]
      assert_no_content_load(queries)
    end
  end

  test "shared message payloads remain cached separately for each user" do
    %{user: owner, password: owner_password} = user_fixture()
    %{user: viewer, password: viewer_password} = user_fixture()
    shared = IntellectualClub.StepRequestsFixtures.shared_request_message!(owner, viewer)
    chat = Ash.get!(Chat, shared.chat_id, actor: owner)
    {:ok, message} = Threads.add_message_to_end(chat, :assistant, "Shared answer", actor: owner)
    owner_conn = sign_in_conn(build_conn(), owner.username, owner_password)
    viewer_conn = sign_in_conn(build_conn(), viewer.username, viewer_password)
    params = %{"working_step_id" => "latest"}
    first = poll(owner_conn, message.id, params) |> json_response(200)

    {response, queries} = measure(fn -> poll(viewer_conn, message.id, params) end)
    assert json_response(response, 200)["content"] == first["content"]
    assert Enum.any?(queries, &String.contains?(&1, "\"content_text\""))

    {response, queries} = measure(fn -> poll(viewer_conn, message.id, params) end)
    assert json_response(response, 200)["working_open"] == first["working_open"]
    assert_no_content_load(queries)
  end

  test "same-count content edits invalidate terminal content and selected details", %{conn: conn} do
    {conn, actor, _chat, message} = fixture(conn)
    first = poll(conn, message.id, %{"working_step_id" => "latest"}) |> json_response(200)
    content_id = hd(first["content"]["parts"])["content_id"]

    Ash.get!(ChatMessageContent, content_id, actor: actor)
    |> Ash.Changeset.for_update(:update, %{content_text: "Changed without adding any item"},
      actor: actor
    )
    |> Ash.update!(actor: actor)

    edited =
      poll(conn, message.id, %{
        "revision" => first["revision"],
        "content_revision" => first["content_revision"],
        "working_step_id" => "latest",
        "working_revision" => first["working_open"]["revision"]
      })
      |> json_response(200)

    assert edited["revision"] != first["revision"]
    assert edited["content_revision"] != first["content_revision"]
    assert edited["working_open"]["revision"] != first["working_open"]["revision"]
    assert hd(edited["content"]["parts"])["text"] == "Changed without adding any item"
  end

  test "historical selection stays independent of the latest step and rejects foreign IDs", %{
    conn: conn
  } do
    {conn, actor, _chat, message} = fixture(conn)
    first = poll(conn, message.id, %{"working_step_id" => "latest"}) |> json_response(200)
    old_id = first["working_open"]["selected_step_id"]

    next =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_id: message.id, sequence: 2, status: :done},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    historical =
      poll(conn, message.id, %{
        "working_step_id" => to_string(old_id),
        "working_revision" => first["working_open"]["revision"]
      })
      |> json_response(200)

    assert historical["working_open"]["step_count"] == 2
    assert historical["working_open"]["selected_step_id"] == old_id
    refute Map.has_key?(historical["working_open"], "step")

    latest =
      poll(conn, message.id, %{
        "working_step_id" => "latest",
        "working_revision" => first["working_open"]["revision"]
      })
      |> json_response(200)

    assert latest["working_open"]["selected_step_id"] == next.id
    assert latest["working_open"]["step"]["id"] == next.id

    chat = Ash.get!(Chat, message.chat_id, actor: actor)

    {:ok, other_message} =
      Threads.add_message_to_end(chat, :assistant, "Other message", actor: actor)

    conn
    |> get("/api/bff/chat-messages/#{other_message.id}/working?step_id=#{old_id}")
    |> response(404)
  end

  test "every request reauthorizes even with a warmed cache and matching revisions", %{conn: conn} do
    {conn, _actor, _chat, message} = fixture(conn)
    first = poll(conn, message.id) |> json_response(200)
    %{user: attacker, password: password} = user_fixture()
    unauthorized = sign_in_conn(build_conn(), attacker.username, password)

    denied =
      poll(unauthorized, message.id, %{
        "revision" => first["revision"],
        "content_revision" => first["content_revision"]
      })

    assert denied.status in [403, 404]
    denied = get(unauthorized, "/api/bff/chat-messages/#{message.id}/working")
    assert denied.status in [403, 404]
  end

  test "busy/initializing workers remain generating; failed absent recovery never cancels", %{
    conn: conn
  } do
    {conn, actor, chat, parent_message} = fixture(conn)
    message = generating_message(chat, parent_message, actor)
    owner = self()

    worker =
      start_supervised!(
        {Task,
         fn ->
           Registry.register(IntellectualClub.Generation.Registry, {:message, message.id}, %{})
           send(owner, :registered)

           receive do
             :finish ->
               Registry.unregister(IntellectualClub.Generation.Registry, {:message, message.id})
           end
         end}
      )

    assert_receive :registered
    payload = poll(conn, message.id) |> json_response(200)
    assert payload["availability"] == "busy"
    assert payload["status"] == "generating"
    assert payload["poll_after_ms"] == 1750
    assert Ash.get!(ChatMessage, message.id, actor: actor).status == :generating
    monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}

    # No retryable step is a recovery error, not authority to cancel this record.
    payload = poll(conn, message.id) |> json_response(200)
    assert payload["status"] == "generating"
    assert Ash.get!(ChatMessage, message.id, actor: actor).status == :generating
  end

  test "streaming updates send only the current step, without loading completed bodies", %{
    conn: conn
  } do
    {conn, actor, chat, parent} = fixture(conn)
    message = generating_message(chat, parent, actor)

    completed =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_id: message.id, sequence: 1, status: :done},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    item =
      IntellectualClub.Chat.ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: completed.id, sequence: 1, type: :answer},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :text,
        content_text: "Completed answer"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_id: message.id, sequence: 2, status: :waiting_provider},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    worker = start_supervised!({LegacyGenerationSnapshotStub, self()})

    publish = fn text ->
      GenServer.call(worker, {:publish_snapshot, message.id, ui_snapshot(step, text, :provider)})
    end

    publish.("first")
    first = poll(conn, message.id, %{"working_step_id" => "latest"}) |> json_response(200)
    assert first["phase"] == "streaming"
    assert first["poll_after_ms"] == 500
    assert Enum.map(first["content"]["parts"], & &1["text"]) == ["Completed answer", "first"]
    publish.("second")

    params = %{
      "revision" => first["revision"],
      "content_revision" => first["content_revision"],
      "runtime_revision" => first["runtime_revision"],
      "working_step_id" => "latest",
      "working_revision" => first["working_open"]["revision"]
    }

    {response, queries} = measure(fn -> poll(conn, message.id, params) end)
    changed = json_response(response, 200)
    refute Map.has_key?(changed, "content")
    assert changed["content_revision"] == first["content_revision"]
    assert changed["runtime_revision"] != first["runtime_revision"]
    assert changed["working_open"]["revision"] != first["working_open"]["revision"]
    assert Enum.map(changed["runtime_content"]["parts"], & &1["text"]) == ["second"]
    assert changed["runtime_step_sequence"] == 2
    assert_no_content_load(queries)
  end

  test "committed predecessor artifacts survive stale runtime before successor acknowledgment", %{
    conn: conn
  } do
    {conn, actor, chat, parent} = fixture(conn)
    message = generating_message(chat, parent, actor)

    completed =
      create!(
        ChatMessageStep,
        %{chat_message_id: message.id, sequence: 1, status: :waiting_tools, response_final: true},
        actor
      )

    answer =
      create!(
        IntellectualClub.Chat.ChatMessageItem,
        %{chat_message_step_id: completed.id, sequence: 1, type: :answer},
        actor
      )

    text =
      create!(
        ChatMessageContent,
        %{
          chat_message_item_id: answer.id,
          sequence: 1,
          kind: :text,
          content_text: "Canonical answer"
        },
        actor
      )

    artifact =
      create!(
        IntellectualClub.Chat.ChatMessageItem,
        %{chat_message_step_id: completed.id, sequence: 2, type: :artifact},
        actor
      )

    {:ok, file} =
      IntellectualClub.Files.create_from_binary("committed.txt", "text/plain", "Durable artifact")

    media =
      create!(
        ChatMessageContent,
        %{chat_message_item_id: artifact.id, sequence: 1, kind: :media, file_id: file.id},
        actor
      )

    worker = start_supervised!({LegacyGenerationSnapshotStub, self()})

    GenServer.call(
      worker,
      {:publish_snapshot, message.id, ui_snapshot(completed, "Stale answer", :persisting)}
    )

    # A durable response already owns this step, even before a successor exists.
    committed = poll(conn, message.id, %{"working_step_id" => "latest"}) |> json_response(200)
    assert hd(committed["content"]["parts"])["content_id"] == text.id
    assert hd(committed["content"]["media"])["id"] == media.id
    assert hd(committed["working_open"]["step"]["items"])["id"] == answer.id

    completed
    |> Ash.Changeset.for_update(:update, %{status: :done}, actor: actor)
    |> Ash.update!(actor: actor)

    successor =
      create!(
        ChatMessageStep,
        %{chat_message_id: message.id, sequence: 2, status: :waiting_provider},
        actor
      )

    boundary =
      poll(conn, message.id, %{
        "working_step_id" => "latest",
        "content_revision" => committed["content_revision"]
      })
      |> json_response(200)

    assert boundary["content_revision"] != committed["content_revision"]
    assert hd(boundary["content"]["parts"])["content_id"] == text.id
    assert hd(boundary["content"]["parts"])["text"] == "Canonical answer"
    assert hd(boundary["content"]["media"])["id"] == media.id
    assert boundary["working_open"]["selected_step_id"] == successor.id

    GenServer.call(
      worker,
      {:publish_snapshot, message.id, ui_snapshot(successor, "New stream", :provider)}
    )

    {response, queries} =
      measure(fn ->
        poll(conn, message.id, %{
          "content_revision" => boundary["content_revision"],
          "runtime_revision" => boundary["runtime_revision"]
        })
      end)

    streaming = json_response(response, 200)
    refute Map.has_key?(streaming, "content")
    assert streaming["content_revision"] == boundary["content_revision"]
    assert streaming["runtime_step_sequence"] == 2
    assert hd(streaming["runtime_content"]["parts"])["text"] == "New stream"
    assert_no_content_load(queries)
  end

  test "cursor polls return suffixes, skip trace metadata on 204, and reconcile a committed step",
       %{conn: conn} do
    {conn, actor, chat, parent} = fixture(conn)
    message = generating_message(chat, parent, actor)

    step =
      create!(
        ChatMessageStep,
        %{chat_message_id: message.id, sequence: 1, status: :waiting_provider},
        actor
      )

    runtime =
      IntellectualClub.Generation.RuntimeTrace.new_step(id: step.id, sequence: 1)
      |> IntellectualClub.Generation.RuntimeTrace.apply_event(
        {:append_text, "reasoning", :reasoning, 1, "Thinking"}
      )
      |> IntellectualClub.Generation.RuntimeTrace.apply_event(
        {:append_text, "answer", :answer, 1, "Привет"}
      )

    worker = start_supervised!({IntellectualClub.Test.RuntimePollStub, {message.id, runtime}})
    first = poll(conn, message.id, %{"poll_protocol" => "cursor"}) |> json_response(200)
    assert hd(first["content"]["parts"])["text"] == "Привет"
    params = cursor_params(first)
    {unchanged, queries} = measure(fn -> poll(conn, message.id, params) end)
    assert response(unchanged, 204) == ""
    assert_no_trace_metadata(queries)

    :ok = GenServer.call(worker, {:event, {:append_text, "answer", :answer, 1, " 🌍"}})
    {changed, queries} = measure(fn -> poll(conn, message.id, params) end)
    next = json_response(changed, 200)
    assert next["runtime_delta"]["text"] == " 🌍"
    assert next["runtime_delta"]["from"] == byte_size("Привет")
    refute Map.has_key?(next, "content")
    refute Map.has_key?(next, "runtime_content")
    assert_no_trace_metadata(queries)
    # A lost response is safely replayed from the old client cursor.
    assert json_response(poll(conn, message.id, params), 200) == next
    :ok = GenServer.call(worker, {:event, {:set_text, "reasoning", :reasoning, 1, "Revised"}})
    assert response(poll(conn, message.id, cursor_params(next)), 204) == ""

    :ok = GenServer.call(worker, {:event, {:set_step_usage, %{output_tokens: 7, cost: 0.1}}})

    {metrics_response, metrics_queries} =
      measure(fn -> poll(conn, message.id, cursor_params(next)) end)

    metrics = json_response(metrics_response, 200)
    assert metrics["runtime_summary"]["output_tokens"] == 7
    assert metrics["runtime_cursor"] == next["runtime_cursor"]
    refute Map.has_key?(metrics, "runtime_content")
    refute Map.has_key?(metrics, "content")
    assert_no_trace_metadata(metrics_queries)

    item =
      create!(
        IntellectualClub.Chat.ChatMessageItem,
        %{chat_message_step_id: step.id, sequence: 1, type: :answer},
        actor
      )

    content =
      create!(
        ChatMessageContent,
        %{
          chat_message_item_id: item.id,
          sequence: 1,
          kind: :text,
          content_text: "Canonical answer"
        },
        actor
      )

    step
    |> Ash.Changeset.for_update(:update, %{response_final: true}, actor: actor)
    |> Ash.update!(actor: actor)

    final = poll(conn, message.id, cursor_params(next)) |> json_response(200)
    assert hd(final["content"]["parts"])["content_id"] == content.id
    assert hd(final["content"]["parts"])["text"] == "Canonical answer"

    assert final["runtime_cursor"] == %{
             "epoch" => next["runtime_cursor"]["epoch"],
             "step" => step.id,
             "sequence" => 1,
             "retired" => true
           }

    refute Map.has_key?(final, "runtime_content")
    # A lost canonical response must replay before the client acknowledges it.
    assert json_response(poll(conn, message.id, cursor_params(next)), 200) == final

    unacknowledged =
      Map.put(cursor_params(next), "runtime_cursor", Jason.encode!(final["runtime_cursor"]))

    assert json_response(poll(conn, message.id, unacknowledged), 200) == final
    snapshots = :sys.get_state(worker).full_snapshots

    {unchanged, queries} = measure(fn -> poll(conn, message.id, cursor_params(final)) end)
    assert response(unchanged, 204) == ""
    assert_no_trace_metadata(queries)
    assert :sys.get_state(worker).full_snapshots == snapshots

    for event <- [
          {:append_text, "answer", :answer, 1, " stale suffix"},
          {:append_text, "new block", :reasoning, 2, "structural change"},
          {:set_step_usage, %{output_tokens: 999}}
        ] do
      :ok = GenServer.call(worker, {:event, event})
      {unchanged, queries} = measure(fn -> poll(conn, message.id, cursor_params(final)) end)
      assert response(unchanged, 204) == ""
      assert_no_trace_metadata(queries)
      assert :sys.get_state(worker).full_snapshots == snapshots
    end

    # Even a retired cursor cannot suppress a subsequent persisted edit.
    content
    |> Ash.Changeset.for_update(:update, %{content_text: "Canonical edit"}, actor: actor)
    |> Ash.update!(actor: actor)

    edited = poll(conn, message.id, cursor_params(final)) |> json_response(200)
    assert hd(edited["content"]["parts"])["text"] == "Canonical edit"
    assert edited["runtime_cursor"] == final["runtime_cursor"]
    assert response(poll(conn, message.id, cursor_params(edited)), 204) == ""

    successor =
      create!(
        ChatMessageStep,
        %{chat_message_id: message.id, sequence: 2, status: :waiting_provider},
        actor
      )

    boundary = poll(conn, message.id, cursor_params(edited)) |> json_response(200)
    assert boundary["runtime_cursor"] == final["runtime_cursor"]

    :sys.replace_state(worker, fn state ->
      %{state | step: %{runtime | id: successor.id, sequence: 2}}
    end)

    successor_reply = poll(conn, message.id, cursor_params(boundary)) |> json_response(200)
    assert successor_reply["runtime_step_sequence"] == 2
    assert hd(successor_reply["runtime_content"]["parts"])["text"] == "Привет"
    refute Map.has_key?(successor_reply["runtime_cursor"], "retired")
    assert response(poll(conn, message.id, cursor_params(successor_reply)), 204) == ""

    :sys.replace_state(worker, &%{&1 | epoch: "replacement-worker"})
    replacement = poll(conn, message.id, cursor_params(successor_reply)) |> json_response(200)
    assert replacement["runtime_cursor"]["epoch"] == "replacement-worker"
    assert replacement["runtime_content"] == successor_reply["runtime_content"]
    assert response(poll(conn, message.id, cursor_params(replacement)), 204) == ""
    assert final["content_revision"] != next["content_revision"]
  end

  test "a step committed after the message was read is delivered, not silently retired", %{
    conn: conn
  } do
    {conn, actor, chat, parent} = fixture(conn)
    message = generating_message(chat, parent, actor)

    step =
      create!(
        ChatMessageStep,
        %{chat_message_id: message.id, sequence: 1, status: :waiting_provider},
        actor
      )

    runtime =
      IntellectualClub.Generation.RuntimeTrace.new_step(id: step.id, sequence: 1)
      |> IntellectualClub.Generation.RuntimeTrace.apply_event(
        {:append_text, "answer", :answer, 1, "Привет"}
      )

    start_supervised!({IntellectualClub.Test.RuntimePollStub, {message.id, runtime}})
    first = poll(conn, message.id, %{"poll_protocol" => "cursor"}) |> json_response(200)
    params = cursor_params(first)
    # The controller reads the message before polling the worker and the trace.
    stale = Ash.get!(ChatMessage, message.id, actor: actor, load: [:poll_revision])

    item =
      create!(
        IntellectualClub.Chat.ChatMessageItem,
        %{chat_message_step_id: step.id, sequence: 1, type: :answer},
        actor
      )

    create!(
      ChatMessageContent,
      %{chat_message_item_id: item.id, sequence: 1, kind: :text, content_text: "Привет, мир"},
      actor
    )

    step
    |> Ash.Changeset.for_update(:update, %{response_final: true}, actor: actor)
    |> Ash.update!(actor: actor)

    runtime_reply =
      IntellectualClub.Generation.Supervisor.poll_generation(
        message.id,
        Jason.decode!(params["runtime_cursor"]),
        protocol: :cursor
      )

    # A phase change forces the full projection branch.
    params = Map.delete(params, "view_revision")

    assert {:ok, payload} =
             IntellectualClubWeb.Bff.ChatPollPayload.cursor_response(
               stale,
               actor,
               runtime_reply,
               params,
               %{queued_messages: [], active_generation_message_id: message.id}
             )

    assert payload.runtime_cursor["retired"]
    assert hd(payload.content.parts).text == "Привет, мир"
    assert payload.content_revision != params["content_revision"]
  end

  test "a new inspector sync resets body and details once, then resumes suffix polling", %{
    conn: conn
  } do
    {conn, actor, chat, parent} = fixture(conn)
    message = generating_message(chat, parent, actor)

    step =
      create!(
        ChatMessageStep,
        %{chat_message_id: message.id, sequence: 1, status: :waiting_provider},
        actor
      )

    runtime =
      IntellectualClub.Generation.RuntimeTrace.new_step(id: step.id, sequence: 1)
      |> IntellectualClub.Generation.RuntimeTrace.apply_event(
        {:append_text, "answer", :answer, 1, "A"}
      )

    worker = start_supervised!({IntellectualClub.Test.RuntimePollStub, {message.id, runtime}})
    inspector = %{"working_step_id" => "latest", "working_sync" => "1"}

    first =
      poll(conn, message.id, Map.put(inspector, "poll_protocol", "cursor"))
      |> json_response(200)

    :ok = GenServer.call(worker, {:event, {:append_text, "answer", :answer, 1, "B"}})
    loaded = get(conn, "/api/bff/chat-messages/#{message.id}/working") |> json_response(200)

    # The client omits the independently loaded working revision until its
    # inspector generation has been aligned with the body cursor.
    reopened =
      poll(
        conn,
        message.id,
        first |> cursor_params() |> Map.merge(%{inspector | "working_sync" => "2"})
      )
      |> json_response(200)

    assert reopened["view_revision"] != first["view_revision"]
    assert hd(reopened["runtime_content"]["parts"])["text"] == "AB"

    inspector_text = fn payload ->
      payload["step"]["items"]
      |> hd()
      |> Map.fetch!("contents")
      |> hd()
      |> Map.fetch!("content_text")
    end

    assert inspector_text.(reopened["working_open"]) == "AB"
    assert inspector_text.(loaded) == "AB"
    assert reopened["runtime_cursor"]["offset"] == 2
    refute Map.has_key?(reopened, "runtime_delta")

    synchronized =
      reopened
      |> cursor_params()
      |> Map.merge(%{inspector | "working_sync" => "2"})
      |> Map.put("working_revision", reopened["working_open"]["revision"])

    # Even an equal prior working revision needs a full first synchronized projection.
    same_snapshot =
      poll(
        conn,
        message.id,
        synchronized |> Map.put("working_sync", "3") |> Map.delete("working_revision")
      )
      |> json_response(200)

    assert same_snapshot["working_open"]["revision"] == reopened["working_open"]["revision"]
    assert same_snapshot["working_open"]["step"] == reopened["working_open"]["step"]
    assert same_snapshot["runtime_content"] == reopened["runtime_content"]

    snapshots = :sys.get_state(worker).full_snapshots
    assert response(poll(conn, message.id, synchronized), 204) == ""
    assert :sys.get_state(worker).full_snapshots == snapshots

    :ok = GenServer.call(worker, {:event, {:append_text, "answer", :answer, 1, "C"}})
    suffix = poll(conn, message.id, synchronized) |> json_response(200)
    assert suffix["runtime_delta"]["text"] == "C"
    assert suffix["runtime_delta"]["from"] == 2
    assert suffix["view_revision"] == reopened["view_revision"]
    refute Map.has_key?(suffix, "working_open")
    refute Map.has_key?(suffix, "runtime_content")
    assert :sys.get_state(worker).full_snapshots == snapshots
  end

  test "cursor 204 invalidates same-count persisted edits and deletion", %{conn: conn} do
    {conn, actor, _chat, message} = fixture(conn)
    first = poll(conn, message.id, %{"poll_protocol" => "cursor"}) |> json_response(200)
    assert response(poll(conn, message.id, cursor_params(first)), 204) == ""
    id = hd(first["content"]["parts"])["content_id"]
    content = Ash.get!(ChatMessageContent, id, actor: actor)

    content
    |> Ash.Changeset.for_update(:update, %{content_text: "edit"}, actor: actor)
    |> Ash.update!(actor: actor)

    edited = poll(conn, message.id, cursor_params(first)) |> json_response(200)
    assert hd(edited["content"]["parts"])["text"] == "edit"
    assert edited["content_revision"] != first["content_revision"]
    Ash.destroy!(content, actor: actor)
    deleted = poll(conn, message.id, cursor_params(edited)) |> json_response(200)
    assert deleted["content"]["parts"] == []
  end

  defp cursor_params(payload) do
    %{
      "poll_protocol" => "cursor",
      "revision" => payload["revision"],
      "view_revision" => payload["view_revision"],
      "content_revision" => payload["content_revision"],
      "runtime_cursor" => Jason.encode!(payload["runtime_cursor"])
    }
  end

  defp assert_no_trace_metadata(queries) do
    refute Enum.any?(queries, fn query ->
             String.contains?(query, ~s(FROM "chat_message_steps")) or
               String.contains?(query, ~s(FROM "chat_message_items")) or
               String.contains?(query, ~s(FROM "chat_message_contents"))
           end)
  end

  defp ui_snapshot(step, text, phase) do
    %{
      status: :generating,
      phase: phase,
      step: %{
        id: step.id,
        sequence: step.sequence,
        status: "waiting_provider",
        items: [
          %{
            id: -1,
            sequence: 1,
            type: "answer",
            contents: [%{id: -2, sequence: 1, kind: "text", content_text: text}]
          }
        ]
      }
    }
  end

  defp create!(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  test "revoked sharing cannot reuse a previously authorized payload or return 204" do
    %{user: owner} = user_fixture()
    %{user: viewer, password: password} = user_fixture()
    shared = IntellectualClub.StepRequestsFixtures.shared_request_message!(owner, viewer)
    chat = Ash.get!(Chat, shared.chat_id, actor: owner)
    {:ok, message} = Threads.add_message_to_end(chat, :assistant, "Shared answer", actor: owner)

    viewer_conn = sign_in_conn(build_conn(), viewer.username, password)
    first = poll(viewer_conn, message.id, %{"working_step_id" => "latest"}) |> json_response(200)
    assert {:ok, _} = IntellectualClub.Sharing.replace_chat_share_state(chat.id, [], owner)

    denied =
      poll(viewer_conn, message.id, %{
        "revision" => first["revision"],
        "content_revision" => first["content_revision"],
        "working_step_id" => "latest",
        "working_revision" => first["working_open"]["revision"]
      })

    assert denied.status in [403, 404]
    assert get(viewer_conn, "/api/bff/chat-messages/#{message.id}/working").status in [403, 404]
  end

  defp fixture(conn) do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, message} = Threads.add_message_to_end(chat, :assistant, "Original answer", actor: actor)
    {conn, actor, chat, message}
  end

  defp generating_message(chat, parent, actor) do
    ChatMessage
    |> Ash.Changeset.for_create(
      :create_generating_assistant,
      %{chat_id: chat.id, parent_id: parent.id, token_count: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp poll(conn, id, params \\ %{}), do: get(conn, "/api/bff/chat-messages/#{id}/poll", params)

  defp assert_no_content_load(queries) do
    refute Enum.any?(queries, &String.contains?(&1, "\"content_text\""))
    refute Enum.any?(queries, &String.contains?(&1, "\"raw_request\""))
    refute Enum.any?(queries, &String.contains?(&1, "\"raw_response\""))
  end

  defp measure(fun) do
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :repo, :query],
        &__MODULE__.handle_query/4,
        {self(), ref}
      )

    try do
      result = fun.()
      {result, drain_queries(ref, [])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def handle_query(_event, _measurements, metadata, {pid, ref}) do
    sql = IO.iodata_to_binary(metadata.query)

    if String.starts_with?(sql, "SELECT") and String.contains?(sql, "\"chat_message_"),
      do: send(pid, {ref, sql})
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, query} -> drain_queries(ref, [query | acc])
    after
      0 -> acc
    end
  end
end
