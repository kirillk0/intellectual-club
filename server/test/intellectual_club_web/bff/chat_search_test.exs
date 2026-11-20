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

    test "skips blank, punctuation-only and short-only queries in either mode", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_empty_chat!(actor)
      {:ok, _} = Threads.add_message_to_end(chat, :user, "до 12", actor: actor)

      for q <- ["", "до 12", "%_|:*"], exact <- ["0", "1"] do
        payload =
          conn
          |> get(~p"/api/bff/chat-search/#{chat.id}/messages", %{q: q, exact: exact})
          |> json_response(200)

        assert payload == %{"active" => [], "inactive" => []}
      end
    end

    test "matches Unicode prefixes case-insensitively but not inside a word", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_empty_chat!(actor)
      {:ok, message} = Threads.add_message_to_end(chat, :user, "Привет миру", actor: actor)
      {:ok, _} = Threads.add_message_to_end(chat, :assistant, "Суперпривет миру", actor: actor)

      payload =
        conn
        |> get(~p"/api/bff/chat-search/#{chat.id}/messages", %{q: "МИР ПРИВ"})
        |> json_response(200)

      assert Enum.map(payload["active"], & &1["id"]) == [message.id]
      assert payload["inactive"] == []

      assert conn
             |> get(~p"/api/bff/chat-search/#{chat.id}/messages", %{q: "рив"})
             |> json_response(200) == %{"active" => [], "inactive" => []}
    end

    test "words in order match adjacent prefixes and keep short words whole", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_empty_chat!(actor)
      {:ok, adjacent} = Threads.add_message_to_end(chat, :user, "Базами, на данных", actor: actor)
      {:ok, reversed} = Threads.add_message_to_end(chat, :assistant, "Данные базы", actor: actor)

      {:ok, short_prefix} =
        Threads.add_message_to_end(chat, :user, "Базы навыков данных", actor: actor)

      {:ok, gapped} =
        Threads.add_message_to_end(chat, :assistant, "База на старых данных", actor: actor)

      path = ~p"/api/bff/chat-search/#{chat.id}/messages"
      any_order = conn |> get(path, %{q: "баз на дан"}) |> json_response(200)

      assert Enum.map(any_order["active"], & &1["id"]) == [
               adjacent.id,
               reversed.id,
               short_prefix.id,
               gapped.id
             ]

      assert Enum.all?(any_order["active"], &is_binary(&1["snippet"]))

      ordered = conn |> get(path, %{q: "баз на дан", exact: "1"}) |> json_response(200)
      assert Enum.map(ordered["active"], & &1["id"]) == [adjacent.id]
      assert ordered["inactive"] == []
    end

    test "a shared chat is searchable in place but not in the reader's owner-only list", %{
      conn: conn
    } do
      %{user: owner} = user_fixture()
      %{user: reader} = fixture = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, reader]})
      bot = create_bot!(owner)
      config = create_configuration!(owner, provider: create_provider!(owner))

      chat =
        create_empty_chat!(owner,
          bot_id: bot.id,
          llm_configuration_id: config.id,
          note: "shared prefix"
        )

      {:ok, message} =
        Threads.add_message_to_end(chat, :user, "Sharing printable text", actor: owner)

      share_chat!(owner, chat, group)
      conn = sign_in_conn(conn, fixture)

      inside =
        conn
        |> get(~p"/api/bff/chat-search/#{chat.id}/messages", %{q: "shar prin", exact: "1"})
        |> json_response(200)

      assert Enum.map(inside["active"], & &1["id"]) == [message.id]
      assert hd(inside["active"])["content"] == "Sharing printable text"

      listed =
        conn |> get("/api/bff/chat-list/search", %{q: "shar", compact: "1"}) |> json_response(200)

      assert listed["hits"] == []
      assert listed["notes"] == []
      assert listed["chats"] == []
    end
  end

  describe "GET /api/bff/chat-list/search" do
    test "notes and paginated message hits span inbox and archive in either view", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      active = create_chat!(actor, note: "archive needle active")
      archived = create_chat!(actor, note: "archive needle old")

      for chat <- [active, archived] do
        {:ok, _} = Threads.add_message_to_end(chat, :user, "archive needle", actor: actor)
      end

      {:ok, _} =
        IntellectualClub.Chat.ReadState.mutate(
          archived.id,
          %{"action" => "archive", "expected_state_version" => 0, "observed_revision" => 0},
          actor
        )

      for {view, other_view} <- [{"inbox", "archive"}, {"archive", "inbox"}] do
        result =
          conn
          |> get("/api/bff/chat-list/search", %{q: "needle", view: view, limit: 1})
          |> json_response(200)

        assert Enum.sort(result["notes"]) == Enum.sort([active.id, archived.id])

        assert Map.new(result["chats"], &{&1["id"], &1["read_state"]["is_archived"]}) ==
                 %{active.id => false, archived.id => true}

        assert Enum.map(result["hits"], & &1["chat_id"]) == [archived.id]
        assert is_binary(result["next_cursor"])

        next =
          conn
          |> get("/api/bff/chat-list/search", %{
            q: "needle",
            view: other_view,
            after: result["next_cursor"],
            limit: 1
          })
          |> json_response(200)

        assert next["notes"] == []
        assert Enum.map(next["hits"], & &1["chat_id"]) == [active.id]
        assert is_nil(next["next_cursor"])
      end
    end

    test "compact search preserves archive state, branch links and labels without expanding cards",
         %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      bot = create_bot!(actor, name: "Reporter")
      chat = create_empty_chat!(actor, note: "Publishing report", bot_id: bot.id)
      child = create_subchat!(actor, chat, :fork, note: "unrelated nested note")
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Publish report", actor: actor)

      {:ok, inactive} =
        Threads.add_message(chat, :assistant, "Published report on another branch",
          actor: actor,
          parent_id: root.id
        )

      {:ok, active} =
        Threads.add_message(chat, :assistant, "Public reporting",
          actor: actor,
          parent_id: root.id
        )

      {:ok, _} =
        IntellectualClub.Chat.ReadState.mutate(
          chat.id,
          %{"action" => "archive", "expected_state_version" => 0, "observed_revision" => 0},
          actor
        )

      params = %{q: "publ rep", exact: "1", limit: 2, bot: bot.id}
      full = conn |> get("/api/bff/chat-list/search", params) |> json_response(200)

      compact =
        conn
        |> get("/api/bff/chat-list/search", Map.put(params, :compact, "1"))
        |> json_response(200)

      assert compact["notes"] == [chat.id]
      assert compact["hits"] == full["hits"]

      assert Enum.map(compact["hits"], &{&1["message_id"], &1["chat_id"], &1["active"]}) == [
               {active.id, chat.id, true},
               {inactive.id, chat.id, false}
             ]

      assert [full_card] = full["chats"]
      assert Enum.map(full_card["subchats"], & &1["id"]) == [child.id]
      assert [card] = compact["chats"]
      fields = ~w(id note bot_id bot_name created_at updated_at read_state message_count)
      for field <- fields, do: assert(Map.fetch!(card, field) == Map.fetch!(full_card, field))
      assert card["read_state"]["is_archived"]
      assert card["bot_name"] == bot.name
      assert card["message_count"] == 2

      for field <- ~w(subchats draft_preview blocks_count tools_count),
          do: refute(Map.has_key?(card, field))

      cursor = compact["next_cursor"]
      assert is_binary(cursor)

      next =
        conn
        |> get("/api/bff/chat-list/search", Map.merge(params, %{compact: "1", after: cursor}))
        |> json_response(200)

      assert next["notes"] == []
      assert Enum.map(next["hits"], & &1["message_id"]) == [root.id]
      assert is_nil(next["next_cursor"])
    end

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

      # A GIN-only page, a page filled from recent messages, and a partial
      # recent window completed by the older index tail must page identically.
      {latest_chat, _} = List.last(messages)
      create_subchat!(actor, latest_chat, :fork, note: "unloaded-child-card")

      for {probe_timeout_ms, window} <- [{0, 96}, {5_000, 96}, {5_000, 1}] do
        put_app_env(:chat_search_probe_timeout_ms, probe_timeout_ms)
        put_app_env(:chat_search_probe_window, window)

        {first, capture} =
          SqlCapture.measure(fn ->
            conn
            |> get("/api/bff/chat-list/search", %{q: "page needle", limit: 2, compact: "1"})
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

        refute SqlCapture.returned?(capture, "unloaded-child-card")

        page_queries =
          Enum.filter(capture.queries, fn query ->
            query.select? and query.source == "chat_messages" and query.sql =~ "search_vector" and
              Regex.match?(~r/@@|ts_match_vq|to_tsquery|::tsquery/i, query.sql)
          end)

        assert page_queries != []
        assert Enum.sum(Enum.map(page_queries, & &1.row_count)) == 3
        refute Enum.any?(capture.queries, &("search_vector" in &1.columns))

        for query <- page_queries do
          assert query_limit(query) in 1..3
          assert query.row_count <= query_limit(query)
          refute query.error?
          refute query.sql =~ "content_text"
          refute Regex.match?(~r/\bcount\s*\(/i, query.sql)
        end

        # The recent window reads ordered keys only; disabling it must not
        # fetch the window before performing a direct index search.
        window_queries =
          Enum.filter(capture.queries, fn query ->
            query.select? and query.source == "chat_messages" and "id" in query.columns and
              "created_at" in query.columns and query.sql =~ "ORDER BY" and
              query.sql =~ "LIMIT" and not (query.sql =~ "search_vector")
          end)

        if probe_timeout_ms > 0 do
          assert [candidates] = window_queries
          assert query_limit(candidates) == window
          assert candidates.row_count <= window
        else
          assert window_queries == []
        end

        # Only returned hits are projected to canonical text. Visibility, role,
        # ordering and the original fragments are checked in one SQL snapshot.
        assert [text_read] =
                 Enum.filter(
                   capture.queries,
                   &(&1.select? and &1.sql =~ "ic_message_search_documents")
                 )

        assert text_read.row_count == length(first["hits"])

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
                      compact: "1",
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

    test "matches all prefixes in one canonical message, including prefixes and positions across fragments",
         %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_empty_chat!(actor)
      message = create_message!(actor, chat)
      last_step = create_step!(actor, message, sequence: 2)
      create_text_item!(actor, last_step, "запроса")
      first_step = create_step!(actor, message, sequence: 1)
      create_text_item!(actor, first_step, "выполнения", sequence: 2)
      item = create_item!(actor, first_step, sequence: 1)
      create_content!(actor, item, sequence: 2, content_text: "нирование")
      create_content!(actor, item, sequence: 1, content_text: "пла")

      {:ok, reversed} =
        Threads.add_message_to_end(chat, :user, "Запрос: выполнение планируется", actor: actor)

      {:ok, gapped} =
        Threads.add_message_to_end(chat, :assistant, "Планируем быстро выполнить запрос",
          actor: actor
        )

      {:ok, _} = Threads.add_message_to_end(chat, :user, "Планировать выполнение", actor: actor)
      {:ok, _} = Threads.add_message_to_end(chat, :assistant, "Запросы", actor: actor)

      unordered =
        conn |> get("/api/bff/chat-list/search", %{q: "план выполн запрос"}) |> json_response(200)

      assert unordered["terms"] == ["план", "выполн", "запрос"]

      assert Enum.map(unordered["hits"], & &1["message_id"]) == [
               gapped.id,
               reversed.id,
               message.id
             ]

      ordered =
        conn
        |> get("/api/bff/chat-list/search", %{q: "план выполн запрос", exact: "1"})
        |> json_response(200)

      assert ordered["terms"] == unordered["terms"]
      assert [%{"message_id" => id, "snippet" => snippet}] = ordered["hits"]
      assert id == message.id
      assert snippet =~ "планирование"
      assert snippet =~ "запроса"
    end

    test "technical punctuation separates consecutive prefixes in both notes and message text", %{
      conn: conn
    } do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor, note: "See api.example.com")

      {:ok, match} =
        Threads.add_message_to_end(chat, :user, "Contact ops@api.example.com", actor: actor)

      {:ok, _decoy} =
        Threads.add_message_to_end(chat, :assistant, "api extra example.com", actor: actor)

      page =
        conn
        |> get("/api/bff/chat-list/search", %{q: "API.Exam.Com", exact: "1", compact: "1"})
        |> json_response(200)

      assert page["terms"] == ["api", "exam", "com"]
      assert page["notes"] == [chat.id]
      assert Enum.map(page["hits"], & &1["message_id"]) == [match.id]
    end

    test "a combining mark does not turn a word suffix into a prefix", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor, note: "за́мок")
      {:ok, stored} = Threads.add_message_to_end(chat, :user, "за́мок открыт", actor: actor)

      search = fn q ->
        conn |> get("/api/bff/chat-list/search", %{q: q, compact: "1"}) |> json_response(200)
      end

      assert %{"hits" => [], "notes" => []} = search.("мок")
      visible = search.("за́м")
      assert Enum.map(visible["hits"], & &1["message_id"]) == [stored.id]
      assert visible["notes"] == [chat.id]
    end

    test "ordered terms retain repeated prefixes and apply to notes as well as messages", %{
      conn: conn
    } do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      repeated = create_empty_chat!(actor, note: "Тестируем тестовые данные")
      once = create_empty_chat!(actor, note: "Тестовые данные")
      {:ok, yes} = Threads.add_message_to_end(repeated, :user, repeated.note, actor: actor)
      {:ok, _} = Threads.add_message_to_end(once, :user, once.note, actor: actor)

      result =
        conn
        |> get("/api/bff/chat-list/search", %{q: "ТЕСТ тест дан", exact: "1"})
        |> json_response(200)

      assert result["terms"] == ["тест", "тест", "дан"]
      assert result["notes"] == [repeated.id]
      assert Enum.map(result["hits"], & &1["message_id"]) == [yes.id]
      assert Enum.map(result["chats"], & &1["id"]) == [repeated.id]
    end

    test "ignores short tokens rather than searching for them in messages or in notes", %{
      conn: conn
    } do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_empty_chat!(actor, note: "до 12 сообщений")

      {:ok, message} =
        Threads.add_message_to_end(chat, :user, "сообщение без чисел", actor: actor)

      for q <- [" ", "до 12", "!%!|:*"], exact <- ["0", "1"] do
        payload =
          conn |> get("/api/bff/chat-list/search", %{q: q, exact: exact}) |> json_response(200)

        assert %{
                 "text_search" => false,
                 "hits" => [],
                 "notes" => [],
                 "chats" => [],
                 "terms" => [],
                 "next_cursor" => nil
               } = payload
      end

      result = conn |> get("/api/bff/chat-list/search", %{q: "от 41 сообщ"}) |> json_response(200)
      assert result["text_search"] == true
      assert result["terms"] == ["сообщ"]
      assert result["notes"] == [chat.id]
      assert Enum.map(result["hits"], & &1["message_id"]) == [message.id]
    end

    test "requires a valid cursor scoped to the actor and filters", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)

      {:ok, oldest} =
        Threads.add_message_to_end(chat, :user, "cursor needle oldest", actor: actor)

      {:ok, _newest} =
        Threads.add_message_to_end(chat, :user, "cursor needle newest", actor: actor)

      params = %{q: "curs", limit: 1}
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
          Map.merge(continuation, %{q: "  curs  ", limit: 5})
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

    test "query punctuation is not a boolean operator and only visible text can match", %{
      conn: conn
    } do
      %{user: actor} = fixture = user_fixture()
      %{user: other_actor} = user_fixture()
      conn = sign_in_conn(conn, fixture)
      term = "Needles, tailoring"
      visible = create_chat!(actor)

      {:ok, message} =
        Threads.add_message_to_end(visible, :user, "prefix #{term} suffix", actor: actor)

      foreign = create_chat!(other_actor, note: term)
      {:ok, _} = Threads.add_message_to_end(foreign, :user, term, actor: other_actor)
      decoy = create_chat!(actor)
      {:ok, _} = Threads.add_message_to_end(decoy, :user, "needle only", actor: actor)
      {:ok, _} = Threads.add_message_to_end(decoy, :user, "tail only", actor: actor)
      {:ok, _} = Threads.add_message_to_end(decoy, :user, "unneeded entails", actor: actor)

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
          |> get("/api/bff/chat-list/search", %{q: "NEED:* | !TAIL%"})
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

    test "the ordered snippet shows the matching sequence rather than an earlier isolated prefix",
         %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_empty_chat!(actor)
      decoy = "Планирование вне города"
      match = "Планируем в городе"

      text = decoy <> String.duplicate(" другой текст ", 100) <> match
      {:ok, _} = Threads.add_message_to_end(chat, :user, text, actor: actor)

      payload =
        conn
        |> get("/api/bff/chat-list/search", %{q: "план в гор", exact: "1", compact: "1"})
        |> json_response(200)

      assert [%{"snippet" => snippet}] = payload["hits"]
      assert snippet =~ match
      refute snippet =~ decoy
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

      # All matching text belongs to items beyond the first 200 IDs. Fragments
      # were inserted out of order; their sequence still defines the shown text.
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
