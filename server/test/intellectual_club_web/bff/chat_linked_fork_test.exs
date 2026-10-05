defmodule IntellectualClubWeb.Bff.ChatLinkedForkTest do
  use IntellectualClubWeb.ConnCase, async: false

  import IntellectualClub.Chat.ForkFixtures

  alias IntellectualClub.Chat.{Chat, ChatMessage, Threads}
  alias IntellectualClub.SqlCapture
  alias IntellectualClubWeb.Bff.ChatForkContext

  setup %{conn: conn} = test_context do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    source =
      create_fork_source!(actor,
        root_text: "source request",
        task: "child task",
        step: Map.take(test_context, [:raw_request])
      )

    child = create_fork_child!(actor, source, task: "child task", attrs: %{note: "Linked child"})
    {:ok, local_user} = Threads.add_message_to_end(child, :user, "local follow-up", actor: actor)
    {:ok, local} = Threads.add_message_to_end(child, :assistant, "local answer", actor: actor)

    %{
      conn: conn,
      actor: actor,
      parent: source.chat,
      root: source.root,
      root_content: source.root_content,
      source: source.message,
      step: source.step,
      call: source.call,
      call_content: source.call_content,
      child: child,
      local_user: local_user,
      local: local
    }
  end

  test "state isolates the projected live prefix and export does not expand the whole source",
       f do
    late_result!(f, "LATE TOOL RESULT")
    future_step = create_step!(f.actor, f.source, sequence: 2, response_final: true)
    create_text_item!(f.actor, future_step, "FUTURE STEP")

    {:ok, _future_message} =
      Threads.add_message_to_end(f.parent, :user, "FUTURE MESSAGE", actor: f.actor)

    payload = state(f)
    assert payload["chat"]["history_read_only"] == true
    assert Enum.map(payload["branch"], & &1["id"]) == [f.local_user.id, f.local.id]
    assert payload["active_generation_message_id"] == nil
    context = payload["fork_context"]
    assert context["status"] == "available"
    assert context["live"] and context["read_only"]
    # The live state summarizes the prefix; the parent relation links to the source.
    assert context["task"] == "child task"
    assert context["message_count"] == 2
    assert context["step_count"] == 1
    refute Map.has_key?(context, "messages")
    refute Jason.encode!(context) =~ "source request"

    export = f.conn |> get(~p"/api/bff/chat-state/#{f.child.id}/export") |> json_response(200)
    assert export["root_chat_id"] == f.child.id
    assert Enum.map(export["chats"], & &1["id"]) == [f.child.id]
    exported = hd(export["chats"])["fork_context"]
    assert exported["status"] == "available"
    assert exported["task"] == "child task"
    assert exported["message_count"] == 2
    assert Enum.map(exported["messages"], & &1["source_message_id"]) == [f.root.id, f.source.id]
    text = Jason.encode!(exported)
    assert text =~ "source request"
    assert text =~ "Parent completed response"
    assert text =~ "Fork branch initialized"
    refute text =~ "LATE TOOL RESULT"

    for message <- exported["messages"] do
      assert message["source_url"] == nil
      refute Map.has_key?(message, "id")
      refute Map.has_key?(message, "status")
      refute Map.has_key?(message, "usage")
      refute Map.has_key?(message, "working")
    end

    refute Jason.encode!(export) =~ "FUTURE STEP"
    refute Jason.encode!(export) =~ "FUTURE MESSAGE"
  end

  test "nested fork includes inherited ancestors and only its own physical branch", f do
    step = update_record!(f.actor, first_step!(f.actor, f.local), %{response_final: true})
    call = create_item!(f.actor, step, sequence: 2, type: :tool_call)

    create_content!(f.actor, call,
      kind: :opaque,
      content_json: %{"name" => "agent.fork", "call_id" => "nested", "arguments" => %{}}
    )

    anchor = %{chat: f.child, message: f.local, step: step, item: call}
    nested_fixture = %{f | child: create_linked_chat!(f.actor, anchor, fork_task: "nested task")}
    payload = state(nested_fixture)
    assert payload["branch"] == []
    assert payload["active_generation_message_id"] == nil
    assert payload["fork_context"]["status"] == "available"
    assert payload["fork_context"]["task"] == "nested task"
    assert payload["fork_context"]["message_count"] == 4
    assert payload["fork_context"]["step_count"] == 2

    exported = export_context(nested_fixture)

    assert Enum.map(exported["messages"], & &1["source_message_id"]) == [
             f.root.id,
             f.source.id,
             f.local_user.id,
             f.local.id
           ]

    assert Jason.encode!(exported) =~ "nested task"
    assert Jason.encode!(exported) =~ "child task"
    assert idle(nested_fixture, payload["idle_revision"]) |> response(204) == ""
    update_record!(f.actor, f.root_content, %{content_text: "edited nested ancestor"})
    changed = idle(nested_fixture, payload["idle_revision"]) |> json_response(200)
    refreshed = state(nested_fixture)
    assert refreshed["idle_revision"] == changed["revision"]
    assert Jason.encode!(export_context(nested_fixture)) =~ "edited nested ancestor"
  end

  test "idle follows included source edits but ignores the source future and run metadata", f do
    initial = state(f)
    revision = initial["idle_revision"]
    assert idle(f, revision) |> response(204) == ""

    # Parent history remains editable even when a linked child exists.
    f.conn
    |> patch(~p"/api/bff/chat-messages/#{f.root.id}", %{content: "edited source"})
    |> json_response(200)

    changed = idle(f, revision) |> json_response(200)
    assert changed["revision"] != revision
    next = state(f)
    assert next["idle_revision"] == changed["revision"]
    assert next["fork_context"]["revision"] != initial["fork_context"]["revision"]
    assert Jason.encode!(export_context(f)) =~ "edited source"
    assert idle(f, changed["revision"]) |> response(204) == ""

    late_result!(f, "late result")

    update_record!(f.actor, f.step, %{
      status: :done,
      input_tokens: 123,
      output_tokens: 456,
      raw_response: %{"output" => "private raw response"}
    })

    set_message_status!(f.actor, f.source, :done)
    later = create_step!(f.actor, f.source, sequence: 2, response_final: true)
    create_text_item!(f.actor, later, "later step")
    {:ok, _} = Threads.add_message_to_end(f.parent, :user, "later message", actor: f.actor)

    {:ok, _} =
      Threads.add_message(f.parent, :assistant, "sibling answer",
        actor: f.actor,
        parent_id: f.root.id
      )

    assert idle(f, changed["revision"]) |> response(204) == ""
    assert state(f)["idle_revision"] == changed["revision"]
  end

  test "an unavailable boundary shows a marker, not partial source content, until restored", f do
    before = state(f)
    Ash.destroy!(f.call_content, actor: f.actor)
    missing = idle(f, before["idle_revision"]) |> json_response(200)
    unavailable = state(f)
    assert unavailable["fork_context"]["status"] == "unavailable"
    assert unavailable["fork_context"]["message_count"] == nil
    # The task is stored on the child, so it survives an unavailable source.
    assert unavailable["fork_context"]["task"] == "child task"
    assert length(unavailable["branch"]) == 2
    assert unavailable["idle_revision"] == missing["revision"]
    assert export_context(f)["messages"] == []
    assert idle(f, missing["revision"]) |> response(204) == ""

    create_content!(f.actor, f.call,
      sequence: 2,
      kind: :opaque,
      content_json: f.call_content.content_json
    )

    restored = idle(f, missing["revision"]) |> json_response(200)
    available = state(f)
    assert available["fork_context"]["status"] == "available"
    assert available["idle_revision"] == restored["revision"]
    assert idle(f, restored["revision"]) |> response(204) == ""
  end

  @tag raw_request: %{"large" => String.duplicate("IDLE-MUST-NOT-LOAD-PARENT-PAYLOAD-", 4000)}
  @tag :whitebox
  test "idle SQL never returns inherited text or provider payloads", f do
    marker = "IDLE-MUST-NOT-LOAD-PARENT-PAYLOAD-"
    text = String.duplicate(marker, 4000)
    update_record!(f.actor, f.root_content, %{content_text: text})
    update_record!(f.actor, f.step, %{raw_response: %{"large" => text}})
    revision = state(f)["idle_revision"]
    {conn, capture} = SqlCapture.measure(fn -> idle(f, revision) end)
    assert response(conn, 204) == ""
    assert capture.queries != []
    assert capture.queries |> Enum.map(& &1.result_bytes) |> Enum.sum() < 50_000
    refute SqlCapture.returned?(capture, marker)
    # Guard the optimizer fences as well as transfer size: tiny result sets can
    # still hide repeated policy scans and global JSON detoasting inside the DB.
    assert [aggregate | _] =
             Enum.filter(capture.queries, &String.starts_with?(&1.sql, "WITH RECURSIVE"))

    assert aggregate.sql =~ ~s("revision_messages" AS MATERIALIZED)
    assert aggregate.sql =~ "JOIN LATERAL"
  end

  test "an unexpected presentation failure does not acknowledge a healthy metadata token", f do
    # An invalid internal display option exercises the same recovery path as an
    # unexpected read/serialization exception without changing persisted data.
    {failed, log} =
      ExUnit.CaptureLog.with_log(fn ->
        ChatForkContext.build(f.child, f.actor, messages?: true, links?: :invalid)
      end)

    assert log =~ "Linked fork context for chat #{f.child.id} raised"
    assert failed.status == "unavailable"
    assert failed.messages == []
    refute failed.revision == ChatForkContext.revision(f.child, f.actor)
    assert ChatForkContext.build(f.child, f.actor).status == "available"
  end

  test "a source edit during presentation loading is noticed by the next idle probe", f do
    marker = "REVISION-RACE-OLD-SOURCE"
    content = update_record!(f.actor, f.root_content, %{content_text: marker})
    test_pid = self()

    # Edit the source right after the presentation has read the old text.
    edit = fn ->
      update_record!(f.actor, content, %{content_text: "REVISION-RACE-NEW-SOURCE"})
      send(test_pid, :source_edited)
    end

    {stale_presentation, _capture} =
      SqlCapture.measure(fn -> state(f) end,
        after_query: {&SqlCapture.returned?(&1, marker), edit}
      )

    assert_received :source_edited
    changed = idle(f, stale_presentation["idle_revision"]) |> json_response(200)
    refreshed = state(f)
    assert refreshed["idle_revision"] == changed["revision"]
    assert Jason.encode!(export_context(f)) =~ "REVISION-RACE-NEW-SOURCE"
  end

  test "all BFF history mutations reject local user and assistant messages", f do
    for message <- [f.local_user, f.local] do
      for suffix <- ["delete", "retry-last-step", "steps/999/retry-from-step"] do
        conn = post(f.conn, "/api/bff/chat-messages/#{message.id}/#{suffix}", %{})
        assert json_response(conn, 403)["code"] == "fork_history_read_only"
      end

      assert f.conn
             |> patch(~p"/api/bff/chat-messages/#{message.id}", %{content: "edit"})
             |> json_response(403)
             |> Map.get("code") == "fork_history_read_only"

      for suffix <- ["switch", "activate", "move-to-new-chat"] do
        conn =
          post(f.conn, "/api/bff/chat-branches/#{f.child.id}/#{suffix}", %{message_id: message.id})

        assert json_response(conn, 403)["code"] == "fork_history_read_only"
      end

      assert f.conn
             |> post(~p"/api/bff/chat-generation/#{f.child.id}/branch-to-new-chat", %{
               message_id: message.id
             })
             |> json_response(403)
             |> Map.get("code") == "fork_history_read_only"
    end

    for action <- ["send", "generate"], parent_id <- [nil, f.local_user.id, f.root.id] do
      conn =
        post(f.conn, "/api/bff/chat-generation/#{f.child.id}/#{action}", %{
          parent_id: parent_id,
          content: "branch"
        })

      assert json_response(conn, 403)["code"] == "fork_history_read_only"
    end
  end

  test "inspection, bookmarks, cancel, steer and queued follow-ups stay available", f do
    f.conn |> get(~p"/api/bff/chat-messages/#{f.local.id}/working") |> json_response(200)
    f.conn |> get(~p"/api/bff/chat-state/#{f.child.id}/message-tree") |> json_response(200)
    f.conn |> post(~p"/api/bff/chat-messages/#{f.local.id}/bookmark", %{}) |> json_response(200)
    f.conn |> post(~p"/api/bff/chat-messages/#{f.local.id}/cancel", %{}) |> json_response(200)

    f.local
    |> Ash.Changeset.for_update(:set_generation_state, %{status: :generating}, actor: f.actor)
    |> Ash.update!(actor: f.actor)

    f.conn
    |> post(~p"/api/bff/chat-messages/#{f.local.id}/steer", %{content: "steer task"})
    |> json_response(201)

    f.conn
    |> post(~p"/api/bff/chat-generation/#{f.child.id}/queue", %{content: "next task"})
    |> json_response(201)
  end

  test "direct follow-up send is not treated as a history mutation", f do
    payload =
      f.conn
      |> post(~p"/api/bff/chat-generation/#{f.child.id}/send", %{content: "another follow-up"})
      |> json_response(200)

    assert is_integer(payload["generation"]["message_id"])

    assert Enum.any?(payload["branch"], fn message ->
             Enum.any?(message["content"]["parts"], &(&1["text"] == "another follow-up"))
           end)

    wait_for_generation_to_finish(f.conn, payload["generation"]["message_id"])
  end

  test "sharing the child alone never grants access to its private source", f do
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [f.actor, recipient]})

    bot = create_bot!(f.actor, history_mode: :chat)
    configuration = create_configuration!(f.actor, model_name: "demo", timeout_seconds: 300)
    share_bot!(f.actor, bot, group)
    share_configuration!(f.actor, configuration, group)
    pinned = %{bot_id: bot.id, llm_configuration_id: configuration.id}
    update_record!(f.actor, f.child, pinned)

    f.conn
    |> put(~p"/api/bff/chat-shares/#{f.child.id}", %{group_ids: [group.id]})
    |> json_response(200)

    conn = build_conn() |> sign_in_conn(recipient.username, password)
    payload = conn |> get(~p"/api/bff/chat-state/#{f.child.id}") |> json_response(200)
    assert payload["fork_context"]["status"] == "unavailable"
    assert payload["fork_context"]["message_count"] == nil
    assert length(payload["branch"]) == 2
    refute Jason.encode!(payload["fork_context"]) =~ "source request"

    shared_fixture = %{f | conn: conn}
    assert idle(shared_fixture, payload["idle_revision"]) |> response(204) == ""
    update_record!(f.actor, f.parent, pinned)

    f.conn
    |> put(~p"/api/bff/chat-shares/#{f.parent.id}", %{group_ids: [group.id]})
    |> json_response(200)

    granted = idle(shared_fixture, payload["idle_revision"]) |> json_response(200)
    shared_state = state(shared_fixture)
    assert shared_state["fork_context"]["status"] == "available"
    assert shared_state["idle_revision"] == granted["revision"]
    assert idle(shared_fixture, granted["revision"]) |> response(204) == ""

    f.conn
    |> put(~p"/api/bff/chat-shares/#{f.parent.id}", %{group_ids: []})
    |> json_response(200)

    revoked = idle(shared_fixture, granted["revision"]) |> json_response(200)
    private_state = state(shared_fixture)
    assert private_state["fork_context"]["status"] == "unavailable"
    assert private_state["idle_revision"] == revoked["revision"]
    assert idle(shared_fixture, revoked["revision"]) |> response(204) == ""

    step =
      create_step!(f.actor, f.local,
        sequence: 2,
        response_final: true,
        raw_request: %{"input" => "PRIVATE_SOURCE_REQUEST"},
        raw_response: %{"output" => "child response"}
      )

    raw_path = "/api/bff/chat-messages/#{f.local.id}/steps/#{step.id}/raw"

    f.conn |> get(raw_path <> "?kind=request") |> json_response(200)
    conn |> get(raw_path <> "?kind=request") |> json_response(403)
    conn |> get(raw_path) |> json_response(403)
    response = conn |> get(raw_path <> "?kind=response") |> json_response(200)
    assert response["step"]["raw_response"] == %{"output" => "child response"}
    refute Jason.encode!(response) =~ "PRIVATE_SOURCE_REQUEST"

    f.conn
    |> get("/api/bff/chat-messages/#{f.local.id}/steps/999999999/raw")
    |> json_response(404)
  end

  test "direct Ash API cannot bypass linked fork history restrictions", f do
    for {method, path, type, attrs} <- [
          {:delete, "/api/ash/chat-messages/#{f.local.id}", "chat-messages", %{}},
          {:post, "/api/ash/chats/#{f.child.id}/branch", "chats",
           %{
             message_id: f.local_user.id,
             replacement_contents: [%{kind: "text", content_text: "branch"}]
           }},
          {:post, "/api/ash/chats/#{f.child.id}/continue", "chats", %{}},
          {:patch, "/api/ash/chats/#{f.child.id}/activate-branch", "chats",
           %{message_id: f.local_user.id}},
          {:patch, "/api/ash/chats/#{f.child.id}/switch-branch", "chats",
           %{message_id: f.local_user.id, direction: "prev"}},
          {:post, "/api/ash/chat-messages/add-user", "chat-messages",
           %{
             chat_id: f.child.id,
             parent_id: f.local_user.id,
             contents: [%{kind: "text", content_text: "branch"}]
           }},
          {:post, "/api/ash/chat-messages/add-user", "chat-messages",
           %{
             chat_id: f.child.id,
             use_active_leaf_parent: false,
             contents: [%{kind: "text", content_text: "root branch"}]
           }}
        ] do
      response = ash_request(f.conn, method, path, type, attrs)

      assert response.status in [400, 403, 422],
             "unexpected status #{response.status}: #{response.resp_body}"

      assert response.resp_body =~ "read-only"
    end

    assert Ash.get!(Chat, f.child.id, actor: f.actor).last_message_id == f.local.id
    assert Ash.get!(ChatMessage, f.local.id, actor: f.actor).id == f.local.id
  end

  test "direct Ash API appends linked followups and rejects a stale explicit parent", f do
    attrs = %{chat_id: f.child.id, contents: [%{kind: "text", content_text: "JSON follow-up"}]}

    payload =
      ash_request(f.conn, :post, "/api/ash/chat-messages/add-user", "chat-messages", attrs)
      |> json_response(201)

    id = String.to_integer(payload["data"]["id"])
    message = Ash.get!(ChatMessage, id, actor: f.actor)
    assert message.parent_id == f.local.id
    assert Ash.get!(Chat, f.child.id, actor: f.actor).last_message_id == id

    response =
      ash_request(
        f.conn,
        :post,
        "/api/ash/chat-messages/add-user",
        "chat-messages",
        Map.put(attrs, :parent_id, f.local.id)
      )

    assert response.status in [400, 403, 422]
    assert response.resp_body =~ "read-only"
    assert Ash.get!(Chat, f.child.id, actor: f.actor).last_message_id == id
  end

  test "public parent references of a linked fork cannot be repointed", f do
    second = create_item!(f.actor, f.step, sequence: 30, type: :tool_call)

    create_content!(f.actor, second,
      kind: :opaque,
      content_json: %{"name" => "agent.fork", "call_id" => "other-call", "arguments" => %{}}
    )

    response =
      ash_request(f.conn, :patch, "/api/ash/chats/#{f.child.id}", "chats", %{
        parent_tool_call_item_id: second.id
      })

    assert response.status in [400, 403, 422]
    assert response.resp_body =~ "cannot change a live fork source"
    assert Ash.get!(Chat, f.child.id, actor: f.actor).parent_tool_call_item_id == f.call.id
  end

  test "legacy chats remain mutable and have no inherited payload", f do
    assert state(%{f | child: f.parent})["fork_context"] == nil
    assert state(%{f | child: f.parent})["chat"]["history_read_only"] == false

    legacy =
      create_empty_chat!(f.actor, %{parent_chat_id: f.parent.id, parent_relation_kind: :fork})

    assert ChatForkContext.build(legacy, f.actor) == nil
    {:ok, message} = Threads.add_message_to_end(legacy, :user, "legacy", actor: f.actor)

    f.conn
    |> patch(~p"/api/bff/chat-messages/#{message.id}", %{content: "legacy edited"})
    |> json_response(200)

    f.conn |> post(~p"/api/bff/chat-messages/#{message.id}/delete", %{}) |> json_response(200)
  end

  test "projected media uses only source content URLs; exports keep placeholders" do
    actor = %{id: 10}

    messages = [
      %{
        id: 7,
        chat_id: 2,
        role: :user,
        steps: [
          %{
            sequence: 1,
            items: [
              %{
                type: :input,
                sequence: 1,
                contents: [
                  %{
                    id: 8,
                    kind: :media,
                    sequence: 1,
                    file: %{id: 9, filename: "image.png", mime_type: "image/png", size_bytes: 20}
                  }
                ]
              }
            ]
          }
        ]
      }
    ]

    sources = %{2 => %{owner_id: 10}}
    [message] = ChatForkContext.serialize_messages(messages, sources, actor)
    [item] = message.content
    assert [%{url: "/api/bff/chat-messages/7/contents/8/file", enabled: true}] = item.attachments
    [export] = ChatForkContext.serialize_messages(messages, sources, actor, links?: false)
    assert [%{attachments: [%{url: nil, enabled: false}]}] = export.content
  end

  defp ash_request(conn, method, path, type, attrs) do
    conn =
      conn
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")

    attrs =
      if method == :post and type == "chat-messages",
        do: Map.put_new(attrs, :use_active_leaf_parent, true),
        else: attrs

    data = %{"type" => type, "attributes" => attrs}

    data =
      case Regex.run(~r{/([0-9]+)(?:/|$)}, path) do
        [_, id] when method == :patch -> Map.put(data, "id", id)
        _ -> data
      end

    case method do
      :post -> post(conn, path, %{"data" => data})
      :patch -> patch(conn, path, %{"data" => data})
      :delete -> delete(conn, path)
    end
  end

  defp idle(f, revision),
    do: get(f.conn, ~p"/api/bff/chat-state/#{f.child.id}/idle-state?revision=#{revision}")

  defp state(f), do: f.conn |> get(~p"/api/bff/chat-state/#{f.child.id}") |> json_response(200)

  defp export_context(f) do
    f.conn
    |> get(~p"/api/bff/chat-state/#{f.child.id}/export")
    |> json_response(200)
    |> Map.fetch!("chats")
    |> hd()
    |> Map.fetch!("fork_context")
  end

  defp late_result!(f, text) do
    create_text_item!(f.actor, f.step, text,
      sequence: 30,
      type: :tool_result,
      tool_call_item_id: f.call.id
    )
  end
end
