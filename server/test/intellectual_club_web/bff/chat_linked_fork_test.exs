defmodule IntellectualClubWeb.Bff.ChatLinkedForkTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep,
    Threads
  }

  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationShare, LlmProvider}
  alias IntellectualClubWeb.Bff.ChatForkContext

  setup %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    parent = create_chat!(actor)
    {:ok, root} = Threads.add_message_to_end(parent, :user, "source request", actor: actor)

    {:ok, source} =
      Threads.add_message_to_end(parent, :assistant, "source response", actor: actor)

    step = first_step!(source, actor)
    step = update!(step, %{response_final: true}, actor)
    call = item!(step, :tool_call, 2, actor)

    call_content =
      content!(
        call,
        %{
          kind: :opaque,
          content_json: %{
            "name" => "agent.fork",
            "call_id" => "fork-call",
            "arguments" => %{"task" => "child task"}
          }
        },
        actor
      )

    child =
      Chat
      |> Ash.Changeset.for_create(
        :create_empty,
        %{
          note: "Linked child",
          parent_chat_id: parent.id,
          parent_message_id: source.id,
          parent_tool_call_item_id: call.id,
          parent_relation_kind: :fork,
          subagent: true
        },
        actor: actor
      )
      |> Ash.Changeset.force_change_attribute(:fork_source_step_id, step.id)
      |> Ash.Changeset.force_change_attribute(:fork_task, "child task")
      |> Ash.create!(actor: actor)

    {:ok, local_user} = Threads.add_message_to_end(child, :user, "local follow-up", actor: actor)
    {:ok, local} = Threads.add_message_to_end(child, :assistant, "local answer", actor: actor)

    %{
      conn: conn,
      actor: actor,
      parent: parent,
      root: root,
      source: source,
      step: step,
      call: call,
      call_content: call_content,
      child: child,
      local_user: local_user,
      local: local
    }
  end

  test "state isolates the projected live prefix and export does not expand the whole source",
       f do
    late = item!(f.step, :tool_result, 3, f.actor, f.call.id)
    content!(late, %{kind: :text, content_text: "LATE TOOL RESULT"}, f.actor)

    future_step =
      create!(
        ChatMessageStep,
        %{chat_message_id: f.source.id, sequence: 2, response_final: true},
        f.actor
      )

    future = item!(future_step, :answer, 1, f.actor)
    content!(future, %{kind: :text, content_text: "FUTURE STEP"}, f.actor)

    {:ok, _future_message} =
      Threads.add_message_to_end(f.parent, :user, "FUTURE MESSAGE", actor: f.actor)

    payload = state(f)
    assert payload["chat"]["history_read_only"] == true
    assert Enum.map(payload["branch"], & &1["id"]) == [f.local_user.id, f.local.id]
    assert payload["active_generation_message_id"] == nil
    context = payload["fork_context"]
    assert context["status"] == "available"
    assert context["live"] and context["read_only"]
    assert Enum.map(context["messages"], & &1["source_message_id"]) == [f.root.id, f.source.id]
    text = Jason.encode!(context)
    assert text =~ "source request"
    assert text =~ "source response"
    assert text =~ "child task"
    assert text =~ "Fork branch initialized"
    refute text =~ "LATE TOOL RESULT"
    refute text =~ "FUTURE STEP"
    refute text =~ "FUTURE MESSAGE"

    for message <- context["messages"] do
      assert message["source_url"] == "/chats/#{f.parent.id}"
      refute Map.has_key?(message, "id")
      refute Map.has_key?(message, "status")
      refute Map.has_key?(message, "usage")
      refute Map.has_key?(message, "working")
    end

    export = f.conn |> get(~p"/api/bff/chat-state/#{f.child.id}/export") |> json_response(200)
    assert export["root_chat_id"] == f.child.id
    assert Enum.map(export["chats"], & &1["id"]) == [f.child.id]
    assert hd(export["chats"])["fork_context"]["status"] == "available"
    refute Jason.encode!(export) =~ "FUTURE STEP"
    refute Jason.encode!(export) =~ "FUTURE MESSAGE"
  end

  test "nested fork includes inherited ancestors and only its own physical branch", f do
    step = f.local |> first_step!(f.actor) |> update!(%{response_final: true}, f.actor)
    call = item!(step, :tool_call, 2, f.actor)

    content!(
      call,
      %{
        kind: :opaque,
        content_json: %{"name" => "agent.fork", "call_id" => "nested", "arguments" => %{}}
      },
      f.actor
    )

    nested =
      Chat
      |> Ash.Changeset.for_create(
        :create_empty,
        %{
          parent_chat_id: f.child.id,
          parent_message_id: f.local.id,
          parent_tool_call_item_id: call.id,
          parent_relation_kind: :fork,
          subagent: true
        },
        actor: f.actor
      )
      |> Ash.Changeset.force_change_attribute(:fork_source_step_id, step.id)
      |> Ash.Changeset.force_change_attribute(:fork_task, "nested task")
      |> Ash.create!(actor: f.actor)

    payload = state(%{f | child: nested})
    assert payload["branch"] == []
    assert payload["active_generation_message_id"] == nil
    assert payload["fork_context"]["status"] == "available"

    assert Enum.map(payload["fork_context"]["messages"], & &1["source_message_id"]) == [
             f.root.id,
             f.source.id,
             f.local_user.id,
             f.local.id
           ]

    assert Jason.encode!(payload["fork_context"]) =~ "nested task"
    assert Jason.encode!(payload["fork_context"]) =~ "child task"
    nested_fixture = %{f | child: nested}
    assert idle(nested_fixture, payload["idle_revision"]) |> response(204) == ""
    update!(first_content!(f.root, f.actor), %{content_text: "edited nested ancestor"}, f.actor)
    changed = idle(nested_fixture, payload["idle_revision"]) |> json_response(200)
    refreshed = state(nested_fixture)
    assert refreshed["idle_revision"] == changed["revision"]
    assert Jason.encode!(refreshed["fork_context"]) =~ "edited nested ancestor"
  end

  test "idle revision follows included source edits but ignores source future", f do
    initial = state(f)
    revision = initial["idle_revision"]

    assert f.conn
           |> get(~p"/api/bff/chat-state/#{f.child.id}/idle-state?revision=#{revision}")
           |> response(204) == ""

    # Parent history remains editable even when a linked child exists.
    f.conn
    |> patch(~p"/api/bff/chat-messages/#{f.root.id}", %{content: "edited source"})
    |> json_response(200)

    changed =
      f.conn
      |> get(~p"/api/bff/chat-state/#{f.child.id}/idle-state?revision=#{revision}")
      |> json_response(200)

    assert changed["revision"] != revision
    next = state(f)
    assert next["idle_revision"] == changed["revision"]
    assert Jason.encode!(next["fork_context"]) =~ "edited source"

    late = item!(f.step, :tool_result, 3, f.actor, f.call.id)
    content!(late, %{kind: :text, content_text: "late result"}, f.actor)

    assert f.conn
           |> get(
             ~p"/api/bff/chat-state/#{f.child.id}/idle-state?revision=#{changed["revision"]}"
           )
           |> response(204) == ""
  end

  test "idle detects content-only edits without touching message or step timestamps", f do
    content = first_content!(f.root, f.actor)
    message_before = Ash.get!(ChatMessage, f.root.id, actor: f.actor)
    step_before = first_step!(f.root, f.actor)
    before = state(f)
    update!(content, %{content_text: "content-only source edit"}, f.actor)

    assert Ash.get!(ChatMessage, f.root.id, actor: f.actor).updated_at ==
             message_before.updated_at

    assert first_step!(f.root, f.actor).updated_at == step_before.updated_at
    changed = idle(f, before["idle_revision"]) |> json_response(200)
    after_edit = state(f)
    assert changed["revision"] == after_edit["idle_revision"]
    assert after_edit["fork_context"]["revision"] != before["fork_context"]["revision"]
    assert Jason.encode!(after_edit["fork_context"]) =~ "content-only source edit"
    assert idle(f, changed["revision"]) |> response(204) == ""
  end

  test "idle ignores future branches, steps and anchor completion metadata", f do
    before = state(f)
    revision = before["idle_revision"]

    update!(
      f.step,
      %{
        status: :done,
        input_tokens: 123,
        output_tokens: 456,
        raw_request: %{"input" => "private raw request"},
        raw_response: %{"output" => "private raw response"}
      },
      f.actor
    )

    f.source
    |> Ash.Changeset.for_update(:set_generation_state, %{status: :done}, actor: f.actor)
    |> Ash.update!(actor: f.actor)

    step = create!(ChatMessageStep, %{chat_message_id: f.source.id, sequence: 2}, f.actor)
    item = item!(step, :answer, 1, f.actor)
    content!(item, %{kind: :text, content_text: "later step"}, f.actor)
    {:ok, _} = Threads.add_message_to_end(f.parent, :user, "later message", actor: f.actor)

    {:ok, _} =
      Threads.add_message(f.parent, :assistant, "sibling answer",
        actor: f.actor,
        parent_id: f.root.id
      )

    assert idle(f, revision) |> response(204) == ""
    assert state(f)["idle_revision"] == revision
  end

  test "idle changes when an unavailable call is removed and restored", f do
    before = state(f)
    Ash.destroy!(f.call_content, actor: f.actor)
    missing = idle(f, before["idle_revision"]) |> json_response(200)
    unavailable = state(f)
    assert unavailable["fork_context"]["status"] == "unavailable"
    assert unavailable["fork_context"]["messages"] == []
    assert unavailable["idle_revision"] == missing["revision"]
    assert idle(f, missing["revision"]) |> response(204) == ""

    content!(f.call, %{kind: :opaque, content_json: f.call_content.content_json}, f.actor)
    restored = idle(f, missing["revision"]) |> json_response(200)
    available = state(f)
    assert available["fork_context"]["status"] == "available"
    assert available["idle_revision"] == restored["revision"]
    assert idle(f, restored["revision"]) |> response(204) == ""
  end

  test "idle SQL never returns inherited text or provider payloads", f do
    marker = "IDLE-MUST-NOT-LOAD-PARENT-PAYLOAD-"
    text = String.duplicate(marker, 4000)
    content = first_content!(f.root, f.actor)
    update!(content, %{content_text: text}, f.actor)
    update!(f.step, %{raw_request: %{"large" => text}, raw_response: %{"large" => text}}, f.actor)
    revision = state(f)["idle_revision"]
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :repo, :query],
        &__MODULE__.capture_idle_rows/4,
        {self(), handler}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert idle(f, revision) |> response(204) == ""
    :ok = :telemetry.detach(handler)
    rows = collected_rows(handler)
    assert rows != []
    encoded = :erlang.term_to_binary(rows)
    assert byte_size(encoded) < 50_000
    assert :binary.match(encoded, marker) == :nomatch
    assert_receive {:idle_metadata_sql, ^handler, sql}
    # Guard the optimizer fences as well as transfer size: tiny result sets can
    # still hide repeated policy scans and global JSON detoasting inside the DB.
    assert sql =~ ~s("revision_messages" AS MATERIALIZED)
    assert sql =~ "JOIN LATERAL"
  end

  test "an unexpected presentation failure does not acknowledge a healthy metadata token", f do
    # An invalid internal display option exercises the same recovery path as an
    # unexpected read/serialization exception without changing persisted data.
    {failed, log} =
      ExUnit.CaptureLog.with_log(fn ->
        ChatForkContext.build(f.child, f.actor, links?: :invalid)
      end)

    assert log =~ "Linked fork context for chat #{f.child.id} raised"
    assert failed.status == "unavailable"
    assert failed.messages == []
    refute failed.revision == ChatForkContext.revision(f.child, f.actor)
    assert ChatForkContext.build(f.child, f.actor).status == "available"
  end

  test "a source edit during presentation loading is noticed by the next idle probe", f do
    content = first_content!(f.root, f.actor)
    marker = "REVISION-RACE-OLD-SOURCE"
    content = update!(content, %{content_text: marker}, f.actor)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :repo, :query],
        &__MODULE__.edit_after_payload_read/4,
        {self(), handler, marker, content, f.actor}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    stale_presentation = state(f)
    assert_receive {:source_edited, ^handler}
    assert Jason.encode!(stale_presentation["fork_context"]) =~ marker
    refute Jason.encode!(stale_presentation["fork_context"]) =~ "REVISION-RACE-NEW-SOURCE"
    changed = idle(f, stale_presentation["idle_revision"]) |> json_response(200)
    refreshed = state(f)
    assert refreshed["idle_revision"] == changed["revision"]
    assert Jason.encode!(refreshed["fork_context"]) =~ "REVISION-RACE-NEW-SOURCE"
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

  test "unavailable boundary produces a marker rather than partial source content", f do
    Ash.destroy!(f.call_content, actor: f.actor)
    payload = state(f)
    assert payload["fork_context"]["status"] == "unavailable"
    assert payload["fork_context"]["messages"] == []
    assert length(payload["branch"]) == 2
  end

  test "sharing the child alone never grants access to its private source", f do
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [f.actor, recipient]})

    bot =
      create!(Bot, %{name: "Shared fork bot", first_messages: [], history_mode: :chat}, f.actor)

    provider =
      create!(
        LlmProvider,
        %{name: "Shared fork provider", type: :demo, auth_method: :api_key},
        f.actor
      )

    configuration =
      create!(
        LlmConfiguration,
        %{
          provider_id: provider.id,
          model_name: "demo",
          enabled: true,
          parameters: %{},
          timeout_seconds: 300
        },
        f.actor
      )

    create!(BotShare, %{bot_id: bot.id, user_group_id: group.id}, f.actor)

    create!(
      LlmConfigurationShare,
      %{llm_configuration_id: configuration.id, user_group_id: group.id},
      f.actor
    )

    update!(f.child, %{bot_id: bot.id, llm_configuration_id: configuration.id}, f.actor)

    f.conn
    |> put(~p"/api/bff/chat-shares/#{f.child.id}", %{group_ids: [group.id]})
    |> json_response(200)

    conn = build_conn() |> sign_in_conn(recipient.username, password)
    payload = conn |> get(~p"/api/bff/chat-state/#{f.child.id}") |> json_response(200)
    assert payload["fork_context"]["status"] == "unavailable"
    assert payload["fork_context"]["messages"] == []
    assert length(payload["branch"]) == 2
    refute Jason.encode!(payload["fork_context"]) =~ "source request"

    shared_fixture = %{f | conn: conn}
    assert idle(shared_fixture, payload["idle_revision"]) |> response(204) == ""
    update!(f.parent, %{bot_id: bot.id, llm_configuration_id: configuration.id}, f.actor)

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

    step = first_step!(f.local, f.actor)

    update!(
      step,
      %{
        raw_request: %{"input" => "PRIVATE_SOURCE_REQUEST"},
        raw_response: %{"output" => "child response"}
      },
      f.actor
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
    second = item!(f.step, :tool_call, 3, f.actor)

    content!(
      second,
      %{
        kind: :opaque,
        content_json: %{"name" => "agent.fork", "call_id" => "other-call", "arguments" => %{}}
      },
      f.actor
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
    legacy = create_chat!(f.actor, %{parent_chat_id: f.parent.id, parent_relation_kind: :fork})
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

  defp first_content!(message, actor) do
    step = first_step!(message, actor)
    step = Ash.load!(step, [items: :contents], actor: actor)

    step.items
    |> Enum.min_by(& &1.sequence)
    |> Map.fetch!(:contents)
    |> Enum.min_by(& &1.sequence)
  end

  @doc false
  def capture_idle_rows(_event, _measurements, metadata, {parent, handler}) do
    if self() == parent or parent in Process.get(:"$callers", []) or metadata[:caller] == parent do
      case metadata.result do
        {:ok, %{rows: rows}} when is_list(rows) -> send(parent, {:idle_rows, handler, rows})
        _ -> :ok
      end

      sql = IO.iodata_to_binary(metadata.query)

      if String.starts_with?(sql, "WITH RECURSIVE"),
        do: send(parent, {:idle_metadata_sql, handler, sql})
    end
  end

  defp collected_rows(handler, acc \\ []) do
    receive do
      {:idle_rows, ^handler, rows} -> collected_rows(handler, [rows | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc false
  def edit_after_payload_read(_event, _measurements, metadata, config) do
    {parent, handler, marker, content, actor} = config

    case metadata.result do
      {:ok, %{rows: rows}} when is_list(rows) ->
        if :binary.match(:erlang.term_to_binary(rows), marker) != :nomatch do
          :telemetry.detach(handler)
          update!(content, %{content_text: "REVISION-RACE-NEW-SOURCE"}, actor)
          send(parent, {:source_edited, handler})
        end

      _ ->
        :ok
    end
  end

  defp state(f), do: f.conn |> get(~p"/api/bff/chat-state/#{f.child.id}") |> json_response(200)
  defp create_chat!(actor, attrs \\ %{}), do: create!(Chat, attrs, actor, :create_empty)

  defp create!(resource, attrs, actor, action \\ :create),
    do:
      resource
      |> Ash.Changeset.for_create(action, attrs, actor: actor)
      |> Ash.create!(actor: actor)

  defp update!(record, attrs, actor),
    do:
      record
      |> Ash.Changeset.for_update(:update, attrs, actor: actor)
      |> Ash.update!(actor: actor)

  defp first_step!(message, actor),
    do: Ash.load!(message, :steps, actor: actor).steps |> Enum.min_by(& &1.sequence)

  defp item!(step, type, sequence, actor, call_id \\ nil),
    do:
      create!(
        ChatMessageItem,
        %{
          chat_message_step_id: step.id,
          sequence: sequence,
          type: type,
          tool_call_item_id: call_id
        },
        actor
      )

  defp content!(item, attrs, actor),
    do:
      create!(
        ChatMessageContent,
        Map.merge(%{chat_message_item_id: item.id, sequence: 1}, attrs),
        actor
      )
end
