defmodule IntellectualClubWeb.Bff.ChatSearchTest do
  @moduledoc """
  Search endpoints: in-chat message search and chat list search.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.SearchDeadline
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.SqlCapture

  describe "GET /api/bff/chat-search/:id/messages" do
    test "splits active/inactive hits", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

      {:ok, active_msg} =
        Threads.add_message(chat, :assistant, "Find me active", actor: actor, parent_id: root.id)

      {:ok, inactive_msg} =
        Threads.add_message(chat, :assistant, "Find me inactive",
          actor: actor,
          parent_id: root.id
        )

      {:ok, _branch} = Threads.activate_branch(chat.id, active_msg.id, actor)

      conn = get(conn, ~p"/api/bff/chat-search/#{chat.id}/messages", %{"q" => "Find"})
      payload = json_response(conn, 200)

      assert length(payload["active"] || []) == 1
      assert length(payload["inactive"] || []) == 1

      assert List.first(payload["active"])["id"] == active_msg.id
      assert List.first(payload["inactive"])["id"] == inactive_msg.id

      assert is_binary(List.first(payload["active"])["snippet"])
      assert is_binary(List.first(payload["inactive"])["snippet"])
      assert is_binary(List.first(payload["active"])["finished_at"])
      assert is_binary(List.first(payload["inactive"])["finished_at"])
    end

    test "returns empty results for empty term", %{conn: conn} do
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

      conn = get(conn, ~p"/api/bff/chat-search/#{chat.id}/messages", %{"q" => ""})
      payload = json_response(conn, 200)

      assert payload["active"] == []
      assert payload["inactive"] == []
    end

    test "uses case-insensitive unicode matching", %{
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

      {:ok, message} = Threads.add_message_to_end(chat, :user, "Привет мир", actor: actor)

      conn = get(conn, ~p"/api/bff/chat-search/#{chat.id}/messages", %{"q" => "ПРИВ"})
      payload = json_response(conn, 200)

      assert Enum.map(payload["active"] || [], & &1["id"]) == [message.id]
      assert payload["inactive"] == []
    end

    test "uses adapter-specific substring semantics", %{
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

      {:ok, _message} = Threads.add_message_to_end(chat, :user, "Привет мир", actor: actor)

      conn = get(conn, ~p"/api/bff/chat-search/#{chat.id}/messages", %{"q" => "рив"})
      payload = json_response(conn, 200)

      assert Enum.map(payload["active"] || [], & &1["content"]) == ["Привет мир"]
      assert payload["inactive"] == []
    end

    test "matches every word in any order unless exact is set", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      chat = create_chat!(actor)
      {:ok, ordered} = Threads.add_message_to_end(chat, :user, "alpha beta", actor: actor)

      {:ok, reversed} =
        Threads.add_message_to_end(chat, :assistant, "beta then alpha", actor: actor)

      {:ok, _other} = Threads.add_message_to_end(chat, :assistant, "alpha only", actor: actor)

      words =
        conn
        |> get(~p"/api/bff/chat-search/#{chat.id}/messages", %{"q" => "beta  alpha"})
        |> json_response(200)

      assert Enum.map(words["active"], & &1["id"]) == [ordered.id, reversed.id]
      assert Enum.all?(words["active"], &is_binary(&1["snippet"]))

      exact =
        conn
        |> get(~p"/api/bff/chat-search/#{chat.id}/messages", %{
          "q" => "alpha beta",
          "exact" => "1"
        })
        |> json_response(200)

      assert Enum.map(exact["active"], & &1["id"]) == [ordered.id]

      assert conn
             |> get(~p"/api/bff/chat-search/#{chat.id}/messages", %{
               "q" => "beta alpha",
               "exact" => "true"
             })
             |> json_response(200)
             |> Map.get("active") == []
    end
  end

  describe "GET /api/bff/chat-list/search" do
    setup do
      put_app_env(:chat_search_probe_timeout_ms, 0)
      :ok
    end

    @tag :whitebox
    test "pages hits newest first with bounded reads under every plan", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)

      messages =
        for index <- 1..5 do
          chat = create_chat!(actor)

          {:ok, message} =
            Threads.add_message_to_end(chat, :user, "page needle payload-#{index}", actor: actor)

          {chat, message}
        end

      expected_ids = messages |> Enum.reverse() |> Enum.map(fn {_chat, message} -> message.id end)

      # Probe disabled, probe covering everything, a probe window smaller than
      # the page, and a probe in several chunks must all page identically.
      for {probe_timeout_ms, window, chunk} <- [
            {0, 300, 50},
            {5_000, 300, 50},
            {5_000, 1, 50},
            {5_000, 300, 2}
          ] do
        put_app_env(:chat_search_probe_timeout_ms, probe_timeout_ms)
        put_app_env(:chat_search_probe_window, window)
        put_app_env(:chat_search_probe_chunk, chunk)

        {first, capture} =
          SqlCapture.measure(fn ->
            conn
            |> get("/api/bff/chat-list/search", %{q: "page needle", limit: 2})
            |> json_response(200)
          end)

        assert first["text_search"] == true
        assert first["terms"] == ["page", "needle"]
        assert first["notes"] == []
        assert Enum.map(first["hits"], & &1["message_id"]) == Enum.take(expected_ids, 2)
        assert is_binary(first["next_cursor"])

        assert Enum.map(first["chats"], & &1["id"]) ==
                 first["hits"] |> Enum.map(& &1["chat_id"]) |> Enum.uniq()

        for %{"active" => active, "role" => role, "snippet" => snippet} <- first["hits"] do
          assert active == true
          assert role == "user"
          assert snippet =~ "page needle"
        end

        for index <- 1..3 do
          refute SqlCapture.returned?(capture, "payload-#{index}")
        end

        match_queries =
          Enum.filter(capture.queries, fn query ->
            query.select? and String.contains?(query.sql, "content_text") and
              Regex.match?(~r/\bILIKE\b/i, query.sql)
          end)

        refute Enum.any?(match_queries, &Regex.match?(~r/\bcount\s*\(/i, &1.sql))
        page_queries = Enum.filter(match_queries, &(&1.source == "chat_messages"))
        assert page_queries != []

        # Each plan reads at most one row beyond the page, the rest never
        # re-reads what the probe already found.
        for query <- page_queries do
          assert query_limit(query) in 1..3
          assert query.row_count <= query_limit(query)
          refute query.error?
        end

        if probe_timeout_ms > 0 do
          assert Enum.any?(page_queries, &String.contains?(&1.sql, "OFFSET 0"))
        end

        assert [snippet_query] =
                 Enum.filter(match_queries, &(&1.source == "chat_message_contents"))

        assert "content_text" in snippet_query.columns
        assert snippet_query.row_count <= 2

        ids =
          Stream.unfold(first, fn
            nil ->
              nil

            payload ->
              next =
                case payload["next_cursor"] do
                  nil ->
                    nil

                  cursor ->
                    conn
                    |> get("/api/bff/chat-list/search", %{
                      q: "page needle",
                      limit: 2,
                      after: cursor
                    })
                    |> json_response(200)
                end

              {Enum.map(payload["hits"], & &1["message_id"]), next}
          end)
          |> Enum.to_list()

        assert List.flatten(ids) == expected_ids
        assert Enum.map(ids, &length/1) == [2, 2, 1]
      end
    end

    test "matches chat notes on the first page only and never bot names", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      bot = create_bot!(actor, name: "Release Bot")
      by_bot = create_chat!(actor, bot_id: bot.id)
      {:ok, _} = Threads.add_message_to_end(by_bot, :user, "unrelated text", actor: actor)
      older_note = create_chat!(actor, note: "Release notes draft")
      newer_note = create_chat!(actor, note: "release NOTES final")
      by_text = create_chat!(actor)
      {:ok, hit} = Threads.add_message_to_end(by_text, :user, "the release notes", actor: actor)
      {:ok, newest} = Threads.add_message_to_end(by_bot, :user, "release candidate", actor: actor)

      payload =
        conn
        |> get("/api/bff/chat-list/search", %{q: "notes release", limit: 1})
        |> json_response(200)

      assert payload["notes"] == [newer_note.id, older_note.id]
      assert Enum.map(payload["hits"], & &1["message_id"]) == [hit.id]
      assert is_nil(payload["next_cursor"])

      assert Enum.map(payload["chats"], & &1["id"]) == [newer_note.id, older_note.id, by_text.id]
      refute Enum.any?(payload["chats"], &(&1["id"] == by_bot.id))
      assert Enum.all?(payload["chats"], &Map.has_key?(&1, "message_count"))

      first =
        conn |> get("/api/bff/chat-list/search", %{q: "release", limit: 1}) |> json_response(200)

      assert first["notes"] == [newer_note.id, older_note.id]
      assert Enum.map(first["hits"], & &1["message_id"]) == [newest.id]
      assert Enum.map(first["chats"], & &1["id"]) == [newer_note.id, older_note.id, by_bot.id]
      assert is_binary(first["next_cursor"])

      second =
        conn
        |> get("/api/bff/chat-list/search", %{q: "release", limit: 1, after: first["next_cursor"]})
        |> json_response(200)

      assert second["notes"] == []
      assert Enum.map(second["hits"], & &1["message_id"]) == [hit.id]
      assert is_nil(second["next_cursor"])

      assert Enum.map(second["chats"], & &1["id"]) ==
               Enum.uniq(Enum.map(second["hits"], & &1["chat_id"]))
    end

    test "every word must occur in one message unless exact is set", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)
      {:ok, phrase} = Threads.add_message_to_end(chat, :user, "alpha beta gamma", actor: actor)

      {:ok, reordered} =
        Threads.add_message_to_end(chat, :assistant, "beta, then alpha", actor: actor)

      {:ok, _partial} = Threads.add_message_to_end(chat, :assistant, "alpha only", actor: actor)
      {:ok, _split} = Threads.add_message_to_end(chat, :user, "alpha", actor: actor)
      {:ok, _} = Threads.add_message_to_end(chat, :assistant, "beta", actor: actor)

      words =
        conn |> get("/api/bff/chat-list/search", %{q: " beta  alpha "}) |> json_response(200)

      assert words["terms"] == ["beta", "alpha"]
      assert Enum.map(words["hits"], & &1["message_id"]) == [reordered.id, phrase.id]

      exact =
        conn
        |> get("/api/bff/chat-list/search", %{q: " alpha beta ", exact: "1"})
        |> json_response(200)

      assert exact["terms"] == ["alpha beta"]
      assert Enum.map(exact["hits"], & &1["message_id"]) == [phrase.id]

      reversed =
        conn
        |> get("/api/bff/chat-list/search", %{q: "beta alpha", exact: "true"})
        |> json_response(200)

      assert reversed["hits"] == []
    end

    test "searches text only with an indexable term; shorter terms only filter", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      by_note = create_chat!(actor, note: "x y release notes")
      by_text = create_chat!(actor)
      {:ok, _} = Threads.add_message_to_end(by_text, :user, "x y in message text", actor: actor)
      {:ok, tagged} = Threads.add_message_to_end(by_text, :user, "zq message text", actor: actor)

      short = conn |> get("/api/bff/chat-list/search", %{q: "x y"}) |> json_response(200)
      assert short["text_search"] == false
      assert short["notes"] == [by_note.id]
      assert short["hits"] == []
      assert Enum.map(short["chats"], & &1["id"]) == [by_note.id]

      long = conn |> get("/api/bff/chat-list/search", %{q: "x y in"}) |> json_response(200)
      assert long["text_search"] == false

      indexable = conn |> get("/api/bff/chat-list/search", %{q: "message"}) |> json_response(200)
      assert indexable["text_search"] == true
      assert length(indexable["hits"]) == 2

      filtered =
        conn |> get("/api/bff/chat-list/search", %{q: "zq message"}) |> json_response(200)

      assert filtered["text_search"] == true
      assert Enum.map(filtered["hits"], & &1["message_id"]) == [tagged.id]

      blank = conn |> get("/api/bff/chat-list/search", %{q: "  "}) |> json_response(200)

      assert blank ==
               Map.merge(blank, %{
                 "chats" => [],
                 "notes" => [],
                 "hits" => [],
                 "terms" => [],
                 "next_cursor" => nil,
                 "text_search" => false
               })
    end

    test "requires a valid cursor scoped to the actor and filters", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)

      {:ok, oldest} =
        Threads.add_message_to_end(chat, :user, "cursor needle oldest", actor: actor)

      {:ok, _newest} =
        Threads.add_message_to_end(chat, :user, "cursor needle newest", actor: actor)

      params = %{q: "cursor needle", limit: 1}
      first = conn |> get("/api/bff/chat-list/search", params) |> json_response(200)
      cursor = first["next_cursor"]
      assert is_binary(cursor)
      continuation = Map.put(params, :after, cursor)

      invalid_requests = [
        Map.put(continuation, :after, "not-a-signed-cursor"),
        Map.put(continuation, :after, String.duplicate("x", 2049)),
        Map.put(continuation, :q, "another needle"),
        Map.put(continuation, :exact, "1"),
        Map.put(continuation, :bot, "none")
      ]

      for invalid <- invalid_requests do
        assert %{"error" => "Invalid search cursor", "code" => "invalid_cursor"} =
                 conn |> get("/api/bff/chat-list/search", invalid) |> json_response(422)
      end

      other_conn = sign_in_conn(build_conn(), user_fixture())

      assert %{"code" => "invalid_cursor"} =
               other_conn |> get("/api/bff/chat-list/search", continuation) |> json_response(422)

      # Whitespace and the page size do not change the scope.
      next =
        conn
        |> get(
          "/api/bff/chat-list/search",
          Map.merge(continuation, %{q: "  cursor needle  ", limit: 5})
        )
        |> json_response(200)

      assert Enum.map(next["hits"], & &1["message_id"]) == [oldest.id]
      assert is_nil(next["next_cursor"])
    end

    test "cursors break tied timestamps by descending id without repeats", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)
      timestamp = ~U[2026-01-01 12:00:00.000000Z]

      ids =
        for _ <- 1..3 do
          message = create_message!(actor, chat, role: :user, created_at: timestamp)
          step = create_step!(actor, message)
          create_text_item!(actor, step, "tied needle", type: :input)
          message.id
        end
        |> Enum.sort(:desc)

      final_cursor =
        ids
        |> Enum.with_index(1)
        |> Enum.reduce(nil, fn {id, number}, cursor ->
          params = %{q: "tied needle", limit: 1}
          params = if cursor, do: Map.put(params, :after, cursor), else: params
          payload = conn |> get("/api/bff/chat-list/search", params) |> json_response(200)
          assert Enum.map(payload["hits"], & &1["message_id"]) == [id]
          assert Enum.map(payload["chats"], & &1["id"]) == [chat.id]
          if number < length(ids), do: assert(is_binary(payload["next_cursor"]))
          payload["next_cursor"]
        end)

      assert is_nil(final_cursor)
    end

    test "matches literal raw text only for its owner and eligible content kinds", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      %{user: other_actor} = user_fixture()
      conn = sign_in_conn(conn, fixture)
      term = ~S(needle%_\tail)
      visible = create_chat!(actor)

      {:ok, message} =
        Threads.add_message_to_end(visible, :user, "prefix #{term} suffix", actor: actor)

      foreign = create_chat!(other_actor, note: term)
      {:ok, _} = Threads.add_message_to_end(foreign, :user, term, actor: other_actor)
      decoy = create_chat!(actor)
      {:ok, _} = Threads.add_message_to_end(decoy, :user, "needle-any-tail", actor: actor)

      for {type, kind} <- [{:reasoning, :text}, {:answer, :opaque}] do
        chat = create_chat!(actor)
        hidden_message = create_message!(actor, chat)
        step = create_step!(actor, hidden_message)
        item = create_item!(actor, step, type: type)
        create_content!(actor, item, kind: kind, content_text: term)
      end

      for probe_timeout_ms <- [0, 5_000] do
        put_app_env(:chat_search_probe_timeout_ms, probe_timeout_ms)

        payload =
          conn
          |> get("/api/bff/chat-list/search", %{q: String.upcase(term), exact: "1"})
          |> json_response(200)

        assert payload["text_search"] == true
        assert payload["notes"] == []

        assert [%{"message_id" => message_id, "chat_id" => chat_id, "snippet" => snippet}] =
                 payload["hits"]

        assert chat_id == visible.id
        assert message_id == message.id
        assert snippet =~ term
        assert Enum.map(payload["chats"], & &1["id"]) == [visible.id]
      end
    end

    test "the overall deadline cancels a worker blocked during response enrichment" do
      put_app_env(:chat_search_timeout_ms, 50)
      owner = self()

      assert {:error, :timeout} =
               SearchDeadline.run(fn ->
                 assert {:ok, :matched} = SearchDeadline.run(fn -> :matched end)
                 send(owner, {:search_enrichment, self()})

                 receive do
                   :finish_enrichment -> :unexpected_success
                 end
               end)

      assert_receive {:search_enrichment, worker}
      monitor = Process.monitor(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :noproc}
    end

    test "an exhausted overall budget returns a search_timeout response", %{conn: conn} do
      conn = sign_in_conn(conn, user_fixture())
      put_app_env(:chat_search_timeout_ms, 0)

      assert %{"code" => "search_timeout", "error" => message} =
               conn |> get("/api/bff/chat-list/search", %{q: "needle"}) |> json_response(503)

      assert is_binary(message)
    end

    test "flags inactive-branch hits and counts active messages per chat", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(chat, :user, "arsen root", actor: actor)

      {:ok, inactive} =
        Threads.add_message(chat, :assistant, "arsen inactive answer",
          actor: actor,
          parent_id: root.id
        )

      {:ok, active} =
        Threads.add_message(chat, :assistant, "arsen active answer",
          actor: actor,
          parent_id: root.id
        )

      payload = conn |> get("/api/bff/chat-list/search", %{q: "arsen"}) |> json_response(200)

      assert Enum.map(payload["hits"], &{&1["message_id"], &1["active"], &1["role"]}) == [
               {active.id, true, "assistant"},
               {inactive.id, false, "assistant"},
               {root.id, true, "user"}
             ]

      assert Enum.all?(payload["hits"], &(&1["chat_id"] == chat.id))
      assert Enum.all?(payload["hits"], &is_binary(&1["created_at"]))
      assert [%{"id" => chat_id, "message_count" => 2}] = payload["chats"]
      assert chat_id == chat.id
    end

    test "filters notes and hits by bot", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      bot = create_bot!(actor)
      with_bot = create_chat!(actor, bot_id: bot.id, note: "bot needle")

      {:ok, bot_hit} =
        Threads.add_message_to_end(with_bot, :user, "bot needle text", actor: actor)

      without_bot = create_chat!(actor, note: "plain needle")

      {:ok, plain_hit} =
        Threads.add_message_to_end(without_bot, :user, "plain needle text", actor: actor)

      by_bot =
        conn
        |> get("/api/bff/chat-list/search", %{q: "needle", bot: bot.id})
        |> json_response(200)

      assert by_bot["notes"] == [with_bot.id]
      assert Enum.map(by_bot["hits"], & &1["message_id"]) == [bot_hit.id]

      none =
        conn
        |> get("/api/bff/chat-list/search", %{q: "needle", bot: "none"})
        |> json_response(200)

      assert none["notes"] == [without_bot.id]
      assert Enum.map(none["hits"], & &1["message_id"]) == [plain_hit.id]

      assert %{"error" => _} =
               conn
               |> get("/api/bff/chat-list/search", %{q: "needle", bot: "x"})
               |> json_response(422)
    end

    test "returns an expanded snippet around the earliest term", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)
      prefix = String.duplicate("left context ", 24)
      suffix = String.duplicate(" right context", 24)

      {:ok, message} =
        Threads.add_message_to_end(chat, :user, prefix <> "needle" <> suffix <> " tail",
          actor: actor
        )

      payload =
        conn |> get("/api/bff/chat-list/search", %{q: "tail needle"}) |> json_response(200)

      assert [%{"message_id" => message_id, "snippet" => snippet}] = payload["hits"]
      assert message_id == message.id
      assert String.contains?(snippet, "needle")
      assert String.starts_with?(snippet, "...")
      assert String.length(snippet) > 250
    end

    test "finds hits beyond the first trace read chunk", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)
      message = create_message!(actor, chat, parent_id: root.id)
      step = create_step!(actor, message)

      item_payloads =
        Enum.map(1..202, fn sequence ->
          %{chat_message_step_id: step.id, sequence: sequence, type: :answer}
        end)

      %Ash.BulkResult{records: items} =
        Ash.bulk_create!(item_payloads, ChatMessageItem, :create,
          actor: actor,
          return_records?: true
        )

      # Trace items are read in chunks of 200 ids: every hit lives in the second chunk,
      # and the snippet comes from the first matching content of the first matching item.
      item_by_sequence = Map.new(items, &{&1.sequence, &1})

      for {sequence, content_sequence, text} <- [
            {201, 2, "needle late part"},
            {201, 1, "needle first part"},
            {202, 1, "needle next item"}
          ] do
        create_content!(actor, item_by_sequence[sequence],
          sequence: content_sequence,
          content_text: text
        )
      end

      payload = conn |> get("/api/bff/chat-list/search", %{q: "needle"}) |> json_response(200)
      assert [%{"message_id" => message_id, "snippet" => snippet}] = payload["hits"]
      assert message_id == message.id
      assert snippet =~ "needle first part"
    end

    test "excludes subagent chats", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      parent = create_chat!(actor)
      subchat = create_subchat!(actor, parent, :fork, note: "needle subagent note")

      {:ok, _} =
        Threads.add_message_to_end(subchat, :user, "needle subagent message", actor: actor)

      visible = create_chat!(actor)

      {:ok, visible_message} =
        Threads.add_message_to_end(visible, :user, "needle visible", actor: actor)

      payload = conn |> get("/api/bff/chat-list/search", %{q: "needle"}) |> json_response(200)
      assert payload["notes"] == []
      assert Enum.map(payload["hits"], & &1["message_id"]) == [visible_message.id]
      assert Enum.map(payload["chats"], & &1["id"]) == [visible.id]
    end

    test "caps the page size", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)

      for index <- 1..4,
          do:
            {:ok, _} =
              Threads.add_message_to_end(chat, :user, "cap needle #{index}", actor: actor)

      assert conn
             |> get("/api/bff/chat-list/search", %{q: "needle", limit: "0"})
             |> json_response(200)
             |> Map.get("hits")
             |> length() == 4

      assert conn
             |> get("/api/bff/chat-list/search", %{q: "needle", limit: "3"})
             |> json_response(200)
             |> Map.get("hits")
             |> length() == 3
    end
  end

  defp query_limit(query) do
    limits = Regex.scan(~r/\bLIMIT\s+(\$\d+|\d+)/i, query.sql)
    assert limits != [], "Expected a bounded search query: #{query.sql}"
    [_, limit] = List.last(limits)

    case limit do
      "$" <> index -> Enum.at(query.params, String.to_integer(index) - 1)
      literal -> String.to_integer(literal)
    end
  end
end
