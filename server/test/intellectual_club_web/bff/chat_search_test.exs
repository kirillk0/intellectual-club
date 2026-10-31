defmodule IntellectualClubWeb.Bff.ChatSearchTest do
  @moduledoc """
  Search endpoints: in-chat message search and chat list search.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
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

    test "uses adapter-specific multi-token semantics", %{
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

      {:ok, matching} = Threads.add_message_to_end(chat, :user, "alpha beta", actor: actor)
      {:ok, _other} = Threads.add_message_to_end(chat, :assistant, "alpha only", actor: actor)

      exact_order_conn =
        get(conn, ~p"/api/bff/chat-search/#{chat.id}/messages", %{"q" => "alpha beta"})

      exact_order_payload = json_response(exact_order_conn, 200)

      assert Enum.map(exact_order_payload["active"] || [], & &1["id"]) == [matching.id]
      assert exact_order_payload["inactive"] == []

      reversed_conn =
        get(conn, ~p"/api/bff/chat-search/#{chat.id}/messages", %{"q" => "beta alpha"})

      reversed_payload = json_response(reversed_conn, 200)

      assert reversed_payload["active"] == []
      assert reversed_payload["inactive"] == []
    end
  end

  describe "GET /api/bff/chat-list/search" do
    setup do
      put_app_env(:chat_search_probe_timeout_ms, 0)
      :ok
    end

    @tag :whitebox
    test "grouped search bounds section pages and enriches only one matching message per page chat",
         %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      oldest = create_chat!(actor)

      {:ok, oldest_message} =
        Threads.add_message_to_end(oldest, :user, "section needle oldest payload", actor: actor)

      assert {:ok, _} =
               IntellectualClub.Chat.ReadState.mutate(
                 oldest.id,
                 %{"action" => "unread", "expected_state_version" => 0},
                 actor
               )

      others =
        for index <- 1..4 do
          chat = create_chat!(actor)

          {:ok, _} =
            Threads.add_message_to_end(chat, :user, "section needle off-page-payload-#{index}",
              actor: actor
            )

          chat
        end

      for probe_timeout_ms <- [0, 5_000] do
        put_app_env(:chat_search_probe_timeout_ms, probe_timeout_ms)

        {first, capture} =
          SqlCapture.measure(fn ->
            conn
            |> get("/api/bff/chat-list/search", %{
              q: "section needle",
              sections: "unread,other",
              per_page: 1
            })
            |> json_response(200)
          end)

        assert first["text_search"] == true
        assert first["sections"]["unread"]["ids"] == [oldest.id]

        assert first["sections"]["unread"]["page"] == %{
                 "number" => 1,
                 "per_page" => 1,
                 "total" => nil,
                 "has_next" => false,
                 "next_cursor" => nil
               }

        assert first["sections"]["other"]["ids"] == [List.last(others).id]
        assert is_nil(first["sections"]["other"]["page"]["total"])
        assert first["sections"]["other"]["page"]["has_next"]
        assert is_binary(first["sections"]["other"]["page"]["next_cursor"])

        assert Enum.sort(Enum.map(first["chats"], & &1["id"])) ==
                 Enum.sort([oldest.id, List.last(others).id])

        assert %{"message_id" => message_id, "match_type" => "active_message"} =
                 Enum.find(first["chats"], &(&1["id"] == oldest.id))

        assert message_id == oldest_message.id

        for index <- 1..3 do
          refute SqlCapture.returned?(capture, "off-page-payload-#{index}")
        end

        match_queries =
          Enum.filter(capture.queries, fn query ->
            query.select? and String.contains?(query.sql, "content_text") and
              Regex.match?(~r/\bILIKE\b/i, query.sql)
          end)

        # Search never returns a global set of matching ids or asks for an exact count.
        refute Enum.any?(match_queries, &Regex.match?(~r/\bcount\s*\(/i, &1.sql))
        refute Enum.any?(match_queries, &String.contains?(&1.sql, "search_text"))
        page_queries = Enum.filter(match_queries, &(&1.source == "chats"))
        assert length(page_queries) == 2

        for query <- page_queries do
          assert_query_limit(query, 2)
          assert query.row_count <= 2
          refute query.error?

          if probe_timeout_ms > 0 do
            assert query.sql =~ "OFFSET 0"
          end
        end

        message_queries = Enum.filter(match_queries, &(&1.source == "chat_messages"))
        assert length(message_queries) == 2

        for query <- message_queries do
          assert_query_limit(query, 1)
          assert query.row_count <= 1
          refute query.error?
        end

        assert Enum.sum(Enum.map(message_queries, & &1.row_count)) <= length(first["chats"])

        snippet_queries = Enum.filter(match_queries, &(&1.source == "chat_message_contents"))
        assert [snippet_query] = snippet_queries
        assert "content_text" in snippet_query.columns
        assert snippet_query.row_count <= length(first["chats"])
        assert length(match_queries) == length(page_queries) + length(message_queries) + 1

        last =
          others
          |> Enum.reverse()
          |> tl()
          |> Enum.with_index(2)
          |> Enum.reduce(first, fn {chat, number}, previous ->
            cursor = previous["sections"]["other"]["page"]["next_cursor"]
            assert is_binary(cursor)

            payload =
              conn
              |> get("/api/bff/chat-list/search", %{
                q: "section needle",
                sections: "other",
                per_page: 1,
                page_other: number,
                after_other: cursor
              })
              |> json_response(200)

            assert payload["sections"]["other"]["ids"] == [chat.id]
            assert Enum.map(payload["chats"], & &1["id"]) == [chat.id]
            assert payload["sections"]["other"]["page"]["number"] == number
            assert is_nil(payload["sections"]["other"]["page"]["total"])
            assert payload["sections"]["other"]["page"]["has_next"] == number < 4
            payload
          end)

        assert is_nil(last["sections"]["other"]["page"]["next_cursor"])
      end
    end

    test "grouped search matches only chat metadata for terms without three letters or digits in a row",
         %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      by_note = create_chat!(actor, %{note: "x y release notes"})
      by_text = create_chat!(actor)
      {:ok, _} = Threads.add_message_to_end(by_text, :user, "x y in message text", actor: actor)

      short =
        conn
        |> get("/api/bff/chat-list/search", %{q: "x y", sections: "other"})
        |> json_response(200)

      assert short["text_search"] == false
      assert short["sections"]["other"]["ids"] == [by_note.id]
      assert [%{"match_type" => "meta"}] = short["chats"]

      long =
        conn
        |> get("/api/bff/chat-list/search", %{q: "x y in", sections: "other"})
        |> json_response(200)

      assert long["text_search"] == false

      indexable =
        conn
        |> get("/api/bff/chat-list/search", %{q: "message", sections: "other"})
        |> json_response(200)

      assert indexable["text_search"] == true
      assert indexable["sections"]["other"]["ids"] == [by_text.id]

      blank =
        conn
        |> get("/api/bff/chat-list/search", %{q: "  ", sections: "other"})
        |> json_response(200)

      assert blank["chats"] == []

      assert blank["sections"]["other"] == %{
               "ids" => [],
               "page" => %{
                 "number" => 1,
                 "per_page" => 20,
                 "total" => nil,
                 "has_next" => false,
                 "next_cursor" => nil
               }
             }
    end

    test "grouped search rejects unknown sections", %{conn: conn} do
      fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)

      assert %{"error" => "Invalid sections"} =
               conn
               |> get("/api/bff/chat-list/search", %{q: "needle", sections: "other,archive"})
               |> json_response(422)
    end

    test "forced indexed fallback and the probe return the same rare and missing matches",
         %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)

      matching =
        for index <- 1..3 do
          note = if index == 1, do: "rare quasar metadata", else: ""
          chat = create_chat!(actor, note: note)
          {:ok, _} = Threads.add_message_to_end(chat, :user, "rare quasar #{index}", actor: actor)
          chat
        end

      for _ <- 1..3 do
        chat = create_chat!(actor, note: "ordinary metadata")
        {:ok, _} = Threads.add_message_to_end(chat, :user, "ordinary message", actor: actor)
      end

      [fallback, probe] =
        for probe_timeout_ms <- [0, 5_000] do
          put_app_env(:chat_search_probe_timeout_ms, probe_timeout_ms)
          params = %{q: "rare quasar", sections: "other", per_page: 2}
          first = conn |> get("/api/bff/chat-list/search", params) |> json_response(200)
          cursor = first["sections"]["other"]["page"]["next_cursor"]
          assert is_binary(cursor)

          second =
            conn
            |> get(
              "/api/bff/chat-list/search",
              Map.merge(params, %{page_other: 2, after_other: cursor})
            )
            |> json_response(200)

          ids = first["sections"]["other"]["ids"] ++ second["sections"]["other"]["ids"]
          assert ids == Enum.map(Enum.reverse(matching), & &1.id)
          assert is_nil(first["sections"]["other"]["page"]["total"])
          assert is_nil(second["sections"]["other"]["page"]["total"])
          refute second["sections"]["other"]["page"]["has_next"]
          assert is_nil(second["sections"]["other"]["page"]["next_cursor"])

          missing =
            conn
            |> get("/api/bff/chat-list/search", Map.put(params, :q, "missing constellation"))
            |> json_response(200)

          assert missing["chats"] == []
          assert missing["sections"]["other"]["ids"] == []
          assert is_nil(missing["sections"]["other"]["page"]["total"])
          refute missing["sections"]["other"]["page"]["has_next"]
          assert is_nil(missing["sections"]["other"]["page"]["next_cursor"])

          Enum.map(first["chats"] ++ second["chats"], fn chat ->
            Map.take(chat, ["id", "match_type", "message_id", "message_role", "snippet"])
          end)
        end

      assert fallback == probe
    end

    test "grouped search requires a valid cursor scoped to the actor and filters", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      oldest = create_chat!(actor, note: "cursor needle oldest")
      _newest = create_chat!(actor, note: "cursor needle newest")
      params = %{q: "cursor needle", sections: "other", per_page: 1}
      first = conn |> get("/api/bff/chat-list/search", params) |> json_response(200)
      cursor = first["sections"]["other"]["page"]["next_cursor"]
      assert is_binary(cursor)
      continuation = Map.merge(params, %{page_other: 2, after_other: cursor})

      invalid_requests = [
        Map.delete(continuation, :after_other),
        Map.put(continuation, :after_other, "not-a-signed-cursor"),
        Map.put(continuation, :after_other, String.duplicate("x", 2049)),
        Map.put(continuation, :q, "another needle"),
        Map.put(continuation, :bot, "none"),
        Map.put(continuation, :per_page, 2),
        Map.merge(continuation, %{sections: "unread", page_unread: 2, after_unread: cursor})
      ]

      for invalid <- invalid_requests do
        assert %{"error" => "Invalid search cursor", "code" => "invalid_cursor"} =
                 conn |> get("/api/bff/chat-list/search", invalid) |> json_response(422)
      end

      other_conn = sign_in_conn(build_conn(), user_fixture())

      assert %{"code" => "invalid_cursor"} =
               other_conn |> get("/api/bff/chat-list/search", continuation) |> json_response(422)

      # The cursor selects the next rows; the number is only a display label.
      next =
        conn
        |> get(
          "/api/bff/chat-list/search",
          Map.merge(continuation, %{q: "  cursor needle  ", page_other: 7})
        )
        |> json_response(200)

      assert next["sections"]["other"]["ids"] == [oldest.id]
      assert next["sections"]["other"]["page"]["number"] == 7
      refute next["sections"]["other"]["page"]["has_next"]
      assert is_nil(next["sections"]["other"]["page"]["next_cursor"])
    end

    test "grouped cursors break tied timestamps by descending id without repeats", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      timestamp = ~U[2026-01-01 12:00:00.000000Z]

      chats =
        for _ <- 1..3 do
          create_empty_chat!(actor, note: "tied needle", updated_at: timestamp)
        end

      assert Enum.all?(chats, &(&1.updated_at == timestamp))
      ids = chats |> Enum.map(& &1.id) |> Enum.sort(:desc)

      final_cursor =
        ids
        |> Enum.with_index(1)
        |> Enum.reduce(nil, fn {id, number}, cursor ->
          params = %{q: "tied needle", sections: "other", per_page: 1, page_other: number}
          params = if cursor, do: Map.put(params, :after_other, cursor), else: params
          payload = conn |> get("/api/bff/chat-list/search", params) |> json_response(200)
          page = payload["sections"]["other"]["page"]
          assert payload["sections"]["other"]["ids"] == [id]
          assert Enum.map(payload["chats"], & &1["id"]) == [id]
          assert page["number"] == number
          assert is_nil(page["total"])
          assert page["has_next"] == number < length(ids)

          if page["has_next"], do: assert(is_binary(page["next_cursor"]))
          page["next_cursor"]
        end)

      assert is_nil(final_cursor)
    end

    test "legacy section and page retain offset pagination and an exact total", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chats = for _ <- 1..3, do: create_chat!(actor, note: "legacy needle")
      _unmatched = create_chat!(actor, note: "unrelated")
      params = %{q: "legacy needle", section: "other", per_page: 2}
      first = conn |> get("/api/bff/chat-list/search", params) |> json_response(200)

      assert Enum.map(first["chats"], & &1["id"]) ==
               chats |> Enum.reverse() |> Enum.take(2) |> Enum.map(& &1.id)

      assert first["page"] == %{"number" => 1, "per_page" => 2, "total" => 3, "has_next" => true}
      refute Map.has_key?(first, "sections")

      last =
        conn |> get("/api/bff/chat-list/search", Map.put(params, :page, 2)) |> json_response(200)

      assert Enum.map(last["chats"], & &1["id"]) == [hd(chats).id]
      assert last["page"] == %{"number" => 2, "per_page" => 2, "total" => 3, "has_next" => false}

      beyond =
        conn |> get("/api/bff/chat-list/search", Map.put(params, :page, 3)) |> json_response(200)

      assert beyond["chats"] == []
      assert beyond["page"]["total"] == 3
      refute beyond["page"]["has_next"]
    end

    test "grouped search matches literal raw text only for its owner and eligible content kinds",
         %{conn: conn} do
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
          |> get("/api/bff/chat-list/search", %{q: String.upcase(term), sections: "other"})
          |> json_response(200)

        assert payload["text_search"] == true
        assert payload["sections"]["other"]["ids"] == [visible.id]

        assert [%{"id" => chat_id, "message_id" => message_id, "snippet" => snippet}] =
                 payload["chats"]

        assert chat_id == visible.id
        assert message_id == message.id
        assert snippet =~ term
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

    test "an exhausted overall budget returns a search_timeout response in every list mode",
         %{conn: conn} do
      conn = sign_in_conn(conn, user_fixture())
      put_app_env(:chat_search_timeout_ms, 0)

      for params <- [
            %{q: "needle", sections: "other"},
            %{q: "needle", section: "other", page: 1},
            %{q: "needle"}
          ] do
        assert %{"code" => "search_timeout", "error" => message} =
                 conn |> get("/api/bff/chat-list/search", params) |> json_response(503)

        assert is_binary(message)
      end
    end

    test "returns meta/active/inactive match types", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      meta_bot = create_bot!(actor, name: "Arsen Bot")

      chat_meta =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "arsen note", bot_id: meta_bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      active_bot = create_bot!(actor, name: "Other Bot")

      chat_active =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: active_bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, active_msg} =
        Threads.add_message_to_end(chat_active, :user, "arsen active message", actor: actor)

      inactive_bot = create_bot!(actor, name: "Another Bot")

      chat_inactive =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: inactive_bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, root} = Threads.add_message_to_end(chat_inactive, :user, "root", actor: actor)

      {:ok, inactive_msg} =
        Threads.add_message(chat_inactive, :assistant, "arsen inactive message",
          actor: actor,
          parent_id: root.id
        )

      {:ok, _active_leaf} =
        Threads.add_message(chat_inactive, :assistant, "Other branch",
          actor: actor,
          parent_id: root.id
        )

      conn = get(conn, ~p"/api/bff/chat-list/search", %{"q" => "arsen"})
      payload = json_response(conn, 200)

      results = payload["chats"] || []

      assert Enum.map(results, & &1["match_type"]) == [
               "meta",
               "active_message",
               "inactive_message"
             ]

      assert Enum.at(results, 0)["id"] == chat_meta.id
      assert Enum.at(results, 0)["message_count"] == 0

      assert Enum.at(results, 1)["id"] == chat_active.id
      assert Enum.at(results, 1)["message_id"] == active_msg.id
      assert Enum.at(results, 1)["message_count"] == 1

      assert Enum.at(results, 2)["id"] == chat_inactive.id
      assert Enum.at(results, 2)["message_id"] == inactive_msg.id
      assert Enum.at(results, 2)["message_count"] == 2

      section_results =
        conn
        |> recycle()
        |> get(~p"/api/bff/chat-list/search", %{"q" => "arsen", "sections" => "other"})
        |> json_response(200)

      assert is_nil(section_results["sections"]["other"]["page"]["total"])

      assert Enum.sort(section_results["sections"]["other"]["ids"]) ==
               Enum.sort(Enum.map(results, & &1["id"]))

      assert Map.new(
               section_results["chats"],
               &{&1["id"], Map.take(&1, ["match_type", "message_id", "message_count", "snippet"])}
             ) ==
               Map.new(
                 results,
                 &{&1["id"],
                  Map.take(&1, ["match_type", "message_id", "message_count", "snippet"])}
               )
    end

    test "prefers active user hits over newer assistant hits", %{
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

      {:ok, user_msg} =
        Threads.add_message_to_end(chat, :user, "needle user message", actor: actor)

      {:ok, _assistant_msg} =
        Threads.add_message(chat, :assistant, "needle assistant message",
          actor: actor,
          parent_id: user_msg.id
        )

      for params <- [%{"q" => "needle"}, %{"q" => "needle", "sections" => "other"}] do
        response = get(conn, ~p"/api/bff/chat-list/search", params)
        payload = json_response(response, 200)
        results = payload["chats"] || []

        result = Enum.find(results, &(&1["id"] == chat.id))

        assert is_map(result)
        assert result["match_type"] == "active_message"
        assert result["message_id"] == user_msg.id
        assert result["message_role"] == "user"
      end
    end

    test "keeps active assistant hits over inactive user hits", %{
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

      {:ok, root} = Threads.add_message_to_end(chat, :user, "root", actor: actor)

      {:ok, _inactive_user} =
        Threads.add_message(chat, :user, "needle inactive user",
          actor: actor,
          parent_id: root.id
        )

      {:ok, active_assistant} =
        Threads.add_message(chat, :assistant, "needle active assistant",
          actor: actor,
          parent_id: root.id
        )

      for params <- [%{"q" => "needle"}, %{"q" => "needle", "sections" => "other"}] do
        response = get(conn, ~p"/api/bff/chat-list/search", params)
        payload = json_response(response, 200)
        results = payload["chats"] || []

        result = Enum.find(results, &(&1["id"] == chat.id))

        assert is_map(result)
        assert result["match_type"] == "active_message"
        assert result["message_id"] == active_assistant.id
        assert result["message_role"] == "assistant"
      end
    end

    test "grouped search prefers newer user hits and breaks message timestamp ties by id",
         %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_empty_chat!(actor)
      older = ~U[2026-01-01 12:00:00.000000Z]
      newer = ~U[2026-01-02 12:00:00.000000Z]

      {messages, _parent_id} =
        Enum.map_reduce([older, newer, newer, older], nil, fn created_at, parent_id ->
          message =
            create_message!(actor, chat,
              role: :user,
              parent_id: parent_id,
              created_at: created_at
            )

          step = create_step!(actor, message)
          item = create_item!(actor, step, type: :input)
          create_content!(actor, item, content_text: "needle ordered hit #{message.id}")
          {message, message.id}
        end)

      assert {:ok, _} = Threads.activate_branch(chat.id, List.last(messages).id, actor)
      expected = Enum.at(messages, 2)

      payload =
        conn
        |> get("/api/bff/chat-list/search", %{q: "needle", sections: "other"})
        |> json_response(200)

      assert [%{"message_id" => message_id, "message_role" => "user"} = result] = payload["chats"]
      assert message_id == expected.id
      assert result["match_type"] == "active_message"
      assert result["snippet"] == "needle ordered hit #{expected.id}"
    end

    test "returns first active message snippet for meta matches", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot = create_bot!(actor, name: "Needle Bot")

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "needle note", bot_id: bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, _first} =
        Threads.add_message_to_end(chat, :user, "First meta line\nSecond meta line", actor: actor)

      conn = get(conn, ~p"/api/bff/chat-list/search", %{"q" => "needle"})
      payload = json_response(conn, 200)
      results = payload["chats"] || []

      result = Enum.find(results, &(&1["id"] == chat.id))

      assert is_map(result)
      assert result["match_type"] == "meta"
      assert result["snippet"] == "First meta line Second meta line"
      assert is_nil(result["message_id"])
      assert is_nil(result["message_role"])
    end

    test "uses case-insensitive matching for message hits", %{
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

      conn = get(conn, ~p"/api/bff/chat-list/search", %{"q" => "ПРИВ"})
      payload = json_response(conn, 200)
      results = payload["chats"] || []

      result = Enum.find(results, &(&1["id"] == chat.id))

      assert is_map(result)
      assert result["match_type"] == "active_message"
      assert result["message_id"] == message.id
      assert is_binary(result["snippet"])
    end

    test "returns expanded snippets around message hits", %{
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

      prefix = String.duplicate("left context ", 24)
      suffix = String.duplicate(" right context", 24)

      {:ok, message} =
        Threads.add_message_to_end(chat, :user, prefix <> "needle" <> suffix, actor: actor)

      conn = get(conn, ~p"/api/bff/chat-list/search", %{"q" => "needle"})
      payload = json_response(conn, 200)
      results = payload["chats"] || []

      result = Enum.find(results, &(&1["id"] == chat.id))

      assert is_map(result)
      assert result["match_type"] == "active_message"
      assert result["message_id"] == message.id
      assert String.contains?(result["snippet"], "needle")
      assert String.length(result["snippet"]) > 250
    end

    test "finds hits beyond the first trace read chunk", %{conn: conn} do
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

      {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

      message =
        ChatMessage
        |> Ash.Changeset.for_create(
          :add_message,
          %{
            chat_id: chat.id,
            role: :assistant,
            parent_id: root.id,
            status: :done,
            token_count: 0
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      step =
        ChatMessageStep
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_id: message.id,
            sequence: 1,
            status: :done,
            raw_request: %{},
            response_final: true
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      item_payloads =
        Enum.map(1..202, fn sequence ->
          %{
            chat_message_step_id: step.id,
            sequence: sequence,
            type: :answer
          }
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

      conn = get(conn, ~p"/api/bff/chat-list/search", %{"q" => "needle"})
      payload = json_response(conn, 200)
      results = payload["chats"] || []

      result = Enum.find(results, &(&1["id"] == chat.id))

      assert is_map(result)
      assert result["match_type"] == "active_message"
      assert result["message_id"] == message.id
      assert result["snippet"] =~ "needle first part"
    end

    test "excludes fork subagent chats", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      parent =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      subchat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{
            note: "needle subagent note",
            parent_chat_id: parent.id,
            parent_relation_kind: :fork,
            subagent: true
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, _subchat_message} =
        Threads.add_message_to_end(subchat, :user, "needle subagent message", actor: actor)

      visible_chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, visible_message} =
        Threads.add_message_to_end(visible_chat, :user, "needle visible message", actor: actor)

      conn = get(conn, ~p"/api/bff/chat-list/search", %{"q" => "needle"})
      payload = json_response(conn, 200)
      results = payload["chats"] || []

      assert Enum.map(results, & &1["id"]) == [visible_chat.id]
      assert List.first(results)["message_id"] == visible_message.id
      refute Enum.any?(results, &(&1["id"] == subchat.id))
    end

    test "excludes chats superseded by continuations", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      first =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: "needle first"}, actor: actor)
        |> Ash.create!(actor: actor)

      terminal =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{
            note: "needle terminal",
            parent_chat_id: first.id,
            parent_relation_kind: :handoff
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      conn = get(conn, ~p"/api/bff/chat-list/search", %{"q" => "needle"})
      payload = json_response(conn, 200)

      assert Enum.map(payload["chats"] || [], & &1["id"]) == [terminal.id]
    end

    test "respects per_page as total result limit", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      Enum.each(1..12, fn idx ->
        chat =
          Chat
          |> Ash.Changeset.for_create(
            :create,
            %{note: ""},
            actor: actor
          )
          |> Ash.create!(actor: actor)

        {:ok, _message} =
          Threads.add_message_to_end(chat, :user, "paged needle #{idx}", actor: actor)
      end)

      conn = get(conn, ~p"/api/bff/chat-list/search", %{"q" => "needle", "per_page" => "5"})
      payload = json_response(conn, 200)
      results = payload["chats"] || []

      assert length(results) == 5
      assert Enum.all?(results, &(&1["match_type"] == "active_message"))
    end
  end

  defp assert_query_limit(query, expected) do
    limits = Regex.scan(~r/\bLIMIT\s+(\$\d+|\d+)/i, query.sql)
    assert limits != [], "Expected a bounded search query: #{query.sql}"
    [_, limit] = List.last(limits)

    actual =
      case limit do
        "$" <> index -> Enum.at(query.params, String.to_integer(index) - 1)
        literal -> String.to_integer(literal)
      end

    assert actual == expected
  end
end
