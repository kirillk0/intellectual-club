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

  alias IntellectualClub.Generation.RuntimeSnapshots
  alias IntellectualClubWeb.Bff.PollCache

  setup do
    for child <- [RuntimeSnapshots, PollCache, SubchatCostCache] do
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

    owner = self()

    worker =
      start_supervised!(
        {Task,
         fn ->
           Registry.register(IntellectualClub.Generation.Registry, {:message, message.id}, %{})
           {:ok, identity} = RuntimeSnapshots.register(message.id)

           publish = fn text ->
             ui_step = %{
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

             :ok =
               RuntimeSnapshots.publish(message.id, identity, %{
                 status: :generating,
                 phase: :provider,
                 step: ui_step
               })
           end

           publish.("first")
           send(owner, :published_first)

           receive do
             :next -> publish.("second")
           end

           send(owner, :published_second)

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive :published_first
    first = poll(conn, message.id, %{"working_step_id" => "latest"}) |> json_response(200)
    assert first["phase"] == "streaming"
    assert first["poll_after_ms"] == 500
    assert Enum.map(first["content"]["parts"], & &1["text"]) == ["Completed answer", "first"]
    send(worker, :next)
    assert_receive :published_second

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

    owner = self()

    worker =
      start_supervised!(
        {Task,
         fn ->
           Registry.register(IntellectualClub.Generation.Registry, {:message, message.id}, %{})
           {:ok, identity} = RuntimeSnapshots.register(message.id)

           stale = %{
             id: completed.id,
             sequence: completed.sequence,
             status: "waiting_tools",
             items: [
               %{
                 id: -1,
                 sequence: 1,
                 type: "answer",
                 contents: [%{id: -2, sequence: 1, kind: "text", content_text: "Stale answer"}]
               }
             ]
           }

           :ok =
             RuntimeSnapshots.publish(message.id, identity, %{
               status: :generating,
               phase: :persisting,
               step: stale
             })

           send(owner, :stale_published)

           receive do
             {:successor, step} ->
               next = %{
                 id: step.id,
                 sequence: step.sequence,
                 status: "waiting_provider",
                 items: [
                   %{
                     id: -3,
                     sequence: 1,
                     type: "answer",
                     contents: [%{id: -4, sequence: 1, kind: "text", content_text: "New stream"}]
                   }
                 ]
               }

               :ok =
                 RuntimeSnapshots.publish(message.id, identity, %{
                   status: :generating,
                   phase: :provider,
                   step: next
                 })

               send(owner, :successor_published)
           end

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive :stale_published

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

    send(worker, {:successor, successor})
    assert_receive :successor_published

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
