defmodule IntellectualClubWeb.Bff.ChatListTest do
  @moduledoc """
  Chat list endpoints (list, summary, search): previews, labels and counts, ordering,
  pagination and stats, the subchat hierarchy and continuation navigation.
  """

  use IntellectualClubWeb.ConnCase, async: true

  import IntellectualClub.HandoffTestHelpers, only: [nav_labels: 1, nav_chat_ids: 1]

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.Threads

  describe "global read-state sections" do
    @tag :whitebox
    test "personal state loading uses a fixed number of queries as the list grows" do
      %{user: actor} = user_fixture()
      chats = for _ <- 1..10, do: create_chat!(actor)

      {single, one} =
        IntellectualClub.SqlCapture.measure(fn ->
          IntellectualClub.Chat.ReadState.load_many(Enum.take(chats, 1), actor)
        end)

      {batch, many} =
        IntellectualClub.SqlCapture.measure(fn ->
          IntellectualClub.Chat.ReadState.load_many(chats, actor)
        end)

      assert map_size(single) == 1
      assert map_size(batch) == 10
      assert length(one.queries) == length(many.queries)
      assert length(many.queries) <= 3
    end

    @tag :whitebox
    test "personal markers return compact aggregates and advance at the snooze deadline" do
      %{user: actor} = user_fixture()
      alias IntellectualClub.Chat.ReadState
      now = DateTime.utc_now()
      deadline = DateTime.add(now, 3600)
      chats = for _ <- 1..20, do: create_chat!(actor)

      for chat <- chats do
        assert {:ok, _} =
                 ReadState.mutate(
                   chat.id,
                   %{
                     "action" => "snooze",
                     "expected_state_version" => 0,
                     "snoozed_until" => DateTime.to_iso8601(deadline)
                   },
                   actor
                 )
      end

      {before, capture} =
        IntellectualClub.SqlCapture.measure(fn -> ReadState.list_marker(actor, now) end)

      assert before.next_expiry == DateTime.to_iso8601(deadline)
      assert before.rows.row_count == 20
      assert before.rows.snoozed_count == 20
      assert before.rows.version_sum == 20
      assert Enum.all?(capture.queries, &(&1.row_count <= 1))

      after_expiry = ReadState.list_marker(actor, DateTime.add(deadline, 1))
      assert is_nil(after_expiry.next_expiry)
      assert after_expiry.rows.snoozed_count == 0
      refute after_expiry.rows == before.rows

      assert {:ok, _} =
               ReadState.mutate(
                 hd(chats).id,
                 %{"action" => "unread", "expected_state_version" => 1},
                 actor
               )

      assert ReadState.list_marker(actor, now).rows.version_sum == 21
    end

    test "working uses the same active branch as the generation indicator", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor, note: "branch-working")
      root = create_message!(actor, chat, role: :user)

      completed =
        create_message!(actor, chat, role: :assistant, parent_id: root.id, status: :done)

      create_generating_message!(actor, chat, parent_id: root.id)
      assert {:ok, _} = Threads.activate_branch(chat.id, completed.id, actor)

      for path <- ["/api/bff/chat-list", "/api/bff/chat-list/search"] do
        working =
          conn |> get(path, %{section: "working", q: "branch-working"}) |> json_response(200)

        assert working["chats"] == []
        assert working["page"]["total"] == 0
        other = conn |> get(path, %{section: "other", q: "branch-working"}) |> json_response(200)
        assert [%{"id" => id, "active_generation_message_id" => nil}] = other["chats"]
        assert id == chat.id
      end
    end

    test "generation completion and observed reads move chats between sections", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)
      child = create_subchat!(actor, chat, :spawn)
      child_message = create_generating_message!(actor, child)
      set_message_status!(actor, child_message, :done)
      message = create_generating_message!(actor, chat)

      for {status, section} <- [{:generating, "working"}, {:done, "unread"}] do
        set_message_status!(actor, Ash.get!(ChatMessage, message.id, actor: actor), status)
        response = conn |> get("/api/bff/chat-list", %{section: section}) |> json_response(200)
        assert Enum.map(response["chats"], & &1["id"]) == [chat.id]
        subchat = hd(hd(response["chats"])["subchats"])
        assert subchat["read_state"]["activity_revision"] == 1
        assert subchat["read_state"]["is_unread"]
        assert subchat["last_message_status"] == "done"
      end

      assert {:ok, _} =
               IntellectualClub.Chat.ReadState.mutate(
                 chat.id,
                 %{
                   "action" => "read",
                   "observed_revision" => 1,
                   "expected_state_version" => 0,
                   "explicit" => true
                 },
                 actor
               )

      other = conn |> get("/api/bff/chat-list", %{section: "other"}) |> json_response(200)
      assert Enum.map(other["chats"], & &1["id"]) == [chat.id]
      unread = conn |> get("/api/bff/chat-list", %{section: "unread"}) |> json_response(200)
      assert unread["page"]["total"] == 0
      assert unread["chats"] == []
    end

    test "sections paginate after filtering and preserve unsectioned stats and sorting", %{
      conn: conn
    } do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      unread = for _ <- 1..3, do: create_chat!(actor, note: "section-match")
      working = create_chat!(actor, note: "section-match")
      other = create_chat!(actor, note: "section-match")
      snoozed = create_chat!(actor, note: "section-match")
      create_generating_message!(actor, working)

      for chat <- unread do
        assert {:ok, _} =
                 IntellectualClub.Chat.ReadState.mutate(
                   chat.id,
                   %{"action" => "unread", "expected_state_version" => 0},
                   actor
                 )
      end

      assert {:ok, _} =
               IntellectualClub.Chat.ReadState.mutate(
                 snoozed.id,
                 %{
                   "action" => "snooze",
                   "expected_state_version" => 0,
                   "snoozed_until" =>
                     DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
                 },
                 actor
               )

      for path <- ["/api/bff/chat-list", "/api/bff/chat-list/search"] do
        first =
          conn
          |> get(path, %{section: "unread", per_page: 2, q: "section-match"})
          |> json_response(200)

        second =
          conn
          |> get(path, %{section: "unread", per_page: 2, page: 2, q: "section-match"})
          |> json_response(200)

        assert first["page"]["total"] == 3
        assert first["page"]["has_next"]
        refute second["page"]["has_next"]

        assert Enum.sort(Enum.map(first["chats"] ++ second["chats"], & &1["id"])) ==
                 Enum.sort(Enum.map(unread, & &1.id))

        active =
          conn |> get(path, %{section: "working", q: "section-match"}) |> json_response(200)

        assert Enum.map(active["chats"], & &1["id"]) == [working.id]
        assert hd(active["chats"])["last_message_status"] == "generating"

        inactive =
          conn |> get(path, %{section: "other", q: "section-match"}) |> json_response(200)

        assert Enum.sort(Enum.map(inactive["chats"], & &1["id"])) ==
                 Enum.sort([other.id, snoozed.id])
      end

      all = conn |> get("/api/bff/chat-list") |> json_response(200)
      filtered = conn |> get("/api/bff/chat-list", %{section: "unread"}) |> json_response(200)
      assert all["stats"] == filtered["stats"]
      assert all["page"]["total"] == 6
      assert Enum.all?(all["chats"], &is_map(&1["read_state"]))
      ids = Enum.map(all["chats"], & &1["id"])

      assert {:ok, _} =
               IntellectualClub.Chat.ReadState.mutate(
                 other.id,
                 %{"action" => "unread", "expected_state_version" => 0},
                 actor
               )

      changed = conn |> get("/api/bff/chat-list") |> json_response(200)
      assert Enum.map(changed["chats"], & &1["id"]) == ids
    end
  end

  describe "GET /api/bff/chat-list" do
    test "returns first_message_preview from the first message", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, first} =
        Threads.add_message_to_end(chat, :user, "First line\nSecond line", actor: actor)

      {:ok, _second} =
        Threads.add_message(chat, :assistant, "Last message", actor: actor, parent_id: first.id)

      conn = get(conn, ~p"/api/bff/chat-list", %{"preview_len" => "10"})
      payload = json_response(conn, 200)

      chat_payload =
        payload
        |> Map.get("chats", [])
        |> Enum.find(fn item -> item["id"] == chat.id end)

      assert is_map(chat_payload)
      assert chat_payload["first_message_preview"] == "First line..."
      assert chat_payload["first_message_role"] == "user"
      assert chat_payload["message_count"] == 2

      assert payload["page"]["number"] == 1
      assert payload["page"]["per_page"] == 20
      assert payload["page"]["has_next"] == false
    end

    test "keeps the original first message preview through nested handoffs",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      source = create_chat!(actor)

      {:ok, opening} =
        Threads.add_message_to_end(source, :assistant, "Original assistant opening", actor: actor)

      {:ok, last_message} =
        Threads.add_message(source, :user, "Continue the work",
          actor: actor,
          parent_id: opening.id
        )

      assert {:ok, %{chat: first_target, message: first_root}} =
               Handoff.create_handoff_chat(source, actor, "First transfer",
                 source_message_id: last_message.id
               )

      assert {:ok, %{chat: terminal_target}} =
               Handoff.create_handoff_chat(first_target, actor, "Nested transfer",
                 source_message_id: first_root.id
               )

      payload =
        conn
        |> get(~p"/api/bff/chat-list", %{"preview_len" => "80"})
        |> json_response(200)

      terminal_payload = chat_payload(payload, terminal_target.id)

      assert is_map(terminal_payload)
      assert terminal_payload["first_message_preview"] == "Original assistant opening"
      assert terminal_payload["first_message_role"] == "assistant"
    end

    test "returns loaded configuration labels", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      provider = create_provider!(actor, name: "List Provider", type: :openrouter_chat_completion)

      configuration =
        create_configuration!(actor,
          provider: provider,
          model_name: "list-model",
          note: "primary",
          context_length: nil
        )

      chat = create_chat!(actor, llm_configuration_id: configuration.id)

      payload =
        conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      chat_payload = chat_payload(payload, chat.id)

      assert is_map(chat_payload)
      assert chat_payload["llm_configuration_id"] == configuration.id
      assert chat_payload["llm_configuration_label"] == "list-model (primary)"
    end

    test "returns chat block and tool counts", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat_with_bindings = create_chat!(actor)
      empty_chat = create_chat!(actor)

      first_block = create_knowledge_block!(actor, content: "Knowledge", name: "List Block A")
      second_block = create_knowledge_block!(actor, content: "Knowledge", name: "List Block B")
      tool = create_tool_instance!(actor, type: "native-agent-management")

      create_chat_block_binding!(actor, chat_with_bindings, first_block)
      create_chat_block_binding!(actor, chat_with_bindings, second_block)
      create_chat_tool_binding!(actor, chat_with_bindings, tool)

      payload =
        conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      chat_payload = chat_payload(payload, chat_with_bindings.id)
      empty_payload = chat_payload(payload, empty_chat.id)

      assert is_map(chat_payload)
      assert chat_payload["blocks_count"] == 2
      assert chat_payload["tools_count"] == 1

      assert is_map(empty_payload)
      assert empty_payload["blocks_count"] == 0
      assert empty_payload["tools_count"] == 0
    end

    test "uses the first message from active branch root", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, _older_root} =
        Threads.add_message(chat, :assistant, "Older root", actor: actor, parent_id: nil)

      {:ok, _active_root} =
        Threads.add_message(chat, :assistant, "Active branch root", actor: actor, parent_id: nil)

      conn = get(conn, ~p"/api/bff/chat-list", %{"preview_len" => "30"})
      payload = json_response(conn, 200)

      chat_payload =
        payload
        |> Map.get("chats", [])
        |> Enum.find(fn item -> item["id"] == chat.id end)

      assert is_map(chat_payload)
      assert chat_payload["first_message_preview"] == "Active branch root"
      assert chat_payload["first_message_role"] == "assistant"
      assert chat_payload["message_count"] == 1
    end

    test "returns active_generation_message_id for generating chats", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: ""},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

      generating_message =
        ChatMessage
        |> Ash.Changeset.for_create(
          :create_generating_assistant,
          %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      conn = get(conn, ~p"/api/bff/chat-list")
      payload = json_response(conn, 200)

      chat_payload =
        payload
        |> Map.get("chats", [])
        |> Enum.find(fn item -> item["id"] == chat.id end)

      assert is_map(chat_payload)
      assert chat_payload["active_generation_message_id"] == generating_message.id
      assert chat_payload["message_count"] == 2
    end
  end

  describe "GET /api/bff/chat-list pagination and stats" do
    test "paginates by page and per_page", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat_a =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      chat_b =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      chat_c =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      conn_page_1 = get(conn, ~p"/api/bff/chat-list", %{"page" => "1", "per_page" => "2"})
      payload_page_1 = json_response(conn_page_1, 200)

      ids_page_1 =
        payload_page_1
        |> Map.get("chats", [])
        |> Enum.map(& &1["id"])

      assert ids_page_1 == [chat_c.id, chat_b.id]
      assert payload_page_1["page"]["number"] == 1
      assert payload_page_1["page"]["per_page"] == 2
      assert payload_page_1["page"]["total"] == 3
      assert payload_page_1["page"]["has_next"] == true

      conn_page_2 = get(conn, ~p"/api/bff/chat-list", %{"page" => "2", "per_page" => "2"})
      payload_page_2 = json_response(conn_page_2, 200)

      ids_page_2 =
        payload_page_2
        |> Map.get("chats", [])
        |> Enum.map(& &1["id"])

      assert ids_page_2 == [chat_a.id]
      assert payload_page_2["page"]["number"] == 2
      assert payload_page_2["page"]["per_page"] == 2
      assert payload_page_2["page"]["total"] == 3
      assert payload_page_2["page"]["has_next"] == false
    end

    test "returns sidebar stats independent from pagination and filter", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot_a = create_bot!(actor, name: "Bot A")
      bot_b = create_bot!(actor, name: "Bot B")

      chat_a =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: bot_a.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      _chat_b1 =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: bot_b.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      _chat_b2 =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: bot_b.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      _chat_without_bot =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      conn =
        get(conn, ~p"/api/bff/chat-list", %{
          "page" => "1",
          "per_page" => "1",
          "bot" => Integer.to_string(bot_a.id)
        })

      payload = json_response(conn, 200)

      assert payload["page"]["number"] == 1
      assert payload["page"]["per_page"] == 1
      assert payload["page"]["total"] == 1
      assert payload["page"]["has_next"] == false

      assert Enum.map(payload["chats"], & &1["id"]) == [chat_a.id]

      assert payload["stats"]["total_chats"] == 4
      assert payload["stats"]["no_bot_chat_count"] == 1
      assert is_binary(payload["stats"]["no_bot_last_activity_at"])

      assert Enum.sort_by(payload["stats"]["bots"], & &1["bot_id"]) == [
               %{"bot_id" => bot_a.id, "bot_name" => "Bot A", "chat_count" => 1},
               %{"bot_id" => bot_b.id, "bot_name" => "Bot B", "chat_count" => 2}
             ]
    end
  end

  describe "GET /api/bff/chat-list ordering" do
    test "keeps message activity order after chat metadata changes", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      older_chat = create_chat!(actor)
      {:ok, _older_message} = Threads.add_message_to_end(older_chat, :user, "Older", actor: actor)

      Process.sleep(20)

      newer_chat = create_chat!(actor)
      {:ok, _newer_message} = Threads.add_message_to_end(newer_chat, :user, "Newer", actor: actor)

      Process.sleep(20)

      conn
      |> json_api_patch(
        "/api/ash/chats/#{older_chat.id}",
        json_api_data("chats", %{"note" => "Renamed older chat"})
      )
      |> json_response(200)

      payload =
        conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      idle_payload =
        conn
        |> get(~p"/api/bff/chat-list/idle-state")
        |> json_response(200)

      assert chat_ids(payload) == [newer_chat.id, older_chat.id]
      assert is_binary(idle_payload["revision"])
    end

    test "sorts by last message finish time", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      long_running_chat = create_chat!(actor)
      {:ok, prompt} = Threads.add_message_to_end(long_running_chat, :user, "Start", actor: actor)

      {:ok, long_running_message} =
        Threads.add_message(long_running_chat, :assistant, "Done later",
          actor: actor,
          parent_id: prompt.id
        )

      newer_started_chat = create_chat!(actor)

      {:ok, _newer_started_message} =
        Threads.add_message_to_end(newer_started_chat, :user, "Started later", actor: actor)

      finished_at =
        long_running_message.finished_at
        |> DateTime.add(60, :second)

      long_running_message
      |> Ash.Changeset.for_update(
        :set_generation_state,
        %{status: :done, finished_at: finished_at},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      payload =
        conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      long_running_payload = chat_payload(payload, long_running_chat.id)

      assert chat_ids(payload) == [long_running_chat.id, newer_started_chat.id]
      assert long_running_payload["last_activity_at"] == DateTime.to_iso8601(finished_at)
    end

    test "sorts empty chats by creation after chat metadata changes", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      older_chat = create_chat!(actor)

      Process.sleep(20)

      newer_chat = create_chat!(actor)

      Process.sleep(20)

      conn
      |> json_api_patch(
        "/api/ash/chats/#{older_chat.id}",
        json_api_data("chats", %{"note" => "Renamed older empty"})
      )
      |> json_response(200)

      payload =
        conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      newer_payload = chat_payload(payload, newer_chat.id)

      assert is_map(newer_payload)
      assert chat_ids(payload) == [newer_chat.id, older_chat.id]
      assert newer_payload["last_activity_at"] == newer_payload["created_at"]
      assert payload["stats"]["no_bot_last_activity_at"] == newer_payload["last_activity_at"]
    end

    test "sorts by active branch leaf instead of newer inactive messages", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      branched_chat = create_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(branched_chat, :user, "Root", actor: actor)

      {:ok, active_leaf} =
        Threads.add_message(branched_chat, :assistant, "Active", actor: actor, parent_id: root.id)

      Process.sleep(20)

      newer_active_chat = create_chat!(actor)

      {:ok, _newer_active_message} =
        Threads.add_message_to_end(newer_active_chat, :user, "Newer active", actor: actor)

      Process.sleep(20)

      {:ok, _inactive_leaf} =
        Threads.add_message(branched_chat, :assistant, "Inactive newer",
          actor: actor,
          parent_id: root.id
        )

      {:ok, _branch_meta} = Threads.activate_branch(branched_chat, active_leaf.id, actor)

      payload =
        conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      branched_payload = chat_payload(payload, branched_chat.id)

      assert is_map(branched_payload)
      assert chat_ids(payload) == [newer_active_chat.id, branched_chat.id]
      assert branched_payload["message_count"] == 2
    end
  end

  describe "GET /api/bff/chat-list subchats and continuations" do
    test "hides fork and spawn subagents and returns them under parent", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      parent = create_chat!(actor)

      {:ok, _parent_message} =
        Threads.add_message_to_end(parent, :user, "Parent prompt", actor: actor)

      fork_subchat =
        create_chat!(actor,
          parent_chat_id: parent.id,
          parent_relation_kind: :fork,
          subagent: true
        )

      {:ok, _fork_message} =
        Threads.add_message_to_end(fork_subchat, :assistant, "Fork answer", actor: actor)

      spawn_subchat =
        create_chat!(actor,
          parent_chat_id: parent.id,
          parent_relation_kind: :spawn,
          subagent: true
        )

      {:ok, _spawn_message} =
        Threads.add_message_to_end(spawn_subchat, :assistant, "Spawn answer", actor: actor)

      normal = create_chat!(actor)

      payload =
        conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      parent_payload = chat_payload(payload, parent.id)
      fork_payload = Enum.find(parent_payload["subchats"], &(&1["id"] == fork_subchat.id))
      spawn_payload = Enum.find(parent_payload["subchats"], &(&1["id"] == spawn_subchat.id))

      assert Enum.sort(chat_ids(payload)) == Enum.sort([parent.id, normal.id])
      refute fork_subchat.id in chat_ids(payload)
      refute spawn_subchat.id in chat_ids(payload)
      assert payload["page"]["total"] == 2
      assert payload["stats"]["total_chats"] == 2

      assert parent_payload["subagent"] == false
      assert parent_payload["child_subchat_count"] == 2
      assert length(parent_payload["subchats"]) == 2

      assert fork_payload["subagent"] == true
      assert fork_payload["parent_chat_id"] == parent.id
      assert fork_payload["parent_relation_kind"] == "fork"
      assert fork_payload["message_count"] == 1
      assert fork_payload["first_message_preview"] == "Fork answer"

      assert spawn_payload["subagent"] == true
      assert spawn_payload["parent_chat_id"] == parent.id
      assert spawn_payload["parent_relation_kind"] == "spawn"
      assert spawn_payload["message_count"] == 1
      assert spawn_payload["first_message_preview"] == "Spawn answer"
    end

    test "returns only terminal chats from continuation chains", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      first = create_chat!(actor)

      middle =
        create_chat!(actor, parent_chat_id: first.id, parent_relation_kind: :handoff)

      terminal =
        create_chat!(actor, parent_chat_id: middle.id, parent_relation_kind: :handoff)

      _old_subchat =
        create_chat!(actor, parent_chat_id: first.id, parent_relation_kind: :fork, subagent: true)

      terminal_subchat =
        create_chat!(actor,
          parent_chat_id: terminal.id,
          parent_relation_kind: :fork,
          subagent: true
        )

      terminal_spawn =
        create_chat!(actor,
          parent_chat_id: terminal.id,
          parent_relation_kind: :spawn,
          subagent: true
        )

      standalone = create_chat!(actor)

      payload =
        conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      assert Enum.sort(chat_ids(payload)) == Enum.sort([terminal.id, standalone.id])
      assert payload["page"]["total"] == 2
      assert payload["stats"]["total_chats"] == 2

      terminal_payload = chat_payload(payload, terminal.id)

      assert terminal_payload["child_subchat_count"] == 2

      assert Enum.map(terminal_payload["subchats"], & &1["id"]) == [
               terminal_subchat.id,
               terminal_spawn.id
             ]
    end

    test "continuations expose relation and navigation hints in list, summary and search", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      source = create_empty_chat!(actor, note: "List source")
      {:ok, source_message} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

      {:ok, %{chat: target}} =
        Handoff.create_handoff_chat(source, actor, "List summary",
          source_message_id: source_message.id
        )

      conn = get(conn, ~p"/api/bff/chat-list")
      payload = json_response(conn, 200)

      source_summary = Enum.find(payload["chats"], &(&1["id"] == source.id))
      target_summary = Enum.find(payload["chats"], &(&1["id"] == target.id))

      assert is_nil(source_summary)
      assert target_summary["parent_chat_id"] == source.id
      assert target_summary["parent_message_id"] == source_message.id
      assert target_summary["parent_relation_kind"] == "handoff"
      assert nav_labels(target_summary) == ["1", "2"]
      assert nav_chat_ids(target_summary) == [source.id, target.id]

      source_summary_payload =
        conn
        |> get(~p"/api/bff/chat-list/#{source.id}/summary")
        |> json_response(200)
        |> Map.fetch!("chat")

      assert nav_labels(source_summary_payload) == ["1", "2"]
      assert nav_chat_ids(source_summary_payload) == [source.id, target.id]

      summary_payload =
        conn
        |> get(~p"/api/bff/chat-list/#{target.id}/summary")
        |> json_response(200)
        |> Map.fetch!("chat")

      assert nav_labels(summary_payload) == ["1", "2"]
      assert nav_chat_ids(summary_payload) == [source.id, target.id]

      search_payload =
        conn
        |> get(~p"/api/bff/chat-list/search", %{"q" => "List summary"})
        |> json_response(200)

      search_target_summary = Enum.find(search_payload["chats"], &(&1["id"] == target.id))
      assert nav_labels(search_target_summary) == ["1", "2"]
      assert nav_chat_ids(search_target_summary) == [source.id, target.id]
    end
  end

  defp chat_ids(payload) do
    payload
    |> Map.get("chats", [])
    |> Enum.map(& &1["id"])
  end

  defp chat_payload(payload, chat_id) do
    payload
    |> Map.get("chats", [])
    |> Enum.find(fn item -> item["id"] == chat_id end)
  end
end
