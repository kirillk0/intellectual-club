defmodule IntellectualClubWeb.Bff.ChatDraftsControllerTest do
  use IntellectualClubWeb.ConnCase, async: true

  alias IntellectualClub.Chat.{Chat, ChatDraft, ReadStateEvents}

  test "missing drafts have version zero and writes preserve exact text", %{conn: conn} do
    %{user: actor} = fixture = user_fixture()
    conn = sign_in_conn(conn, fixture)
    chat = create_chat!(actor)
    path = "/api/bff/chat-drafts/#{chat.id}"
    before_chat = Ash.get!(Chat, chat.id, actor: actor)

    assert %{"draft" => %{"text" => "", "revision" => 0, "updated_at" => nil}} =
             conn |> get(path) |> json_response(200)

    saved = conn |> put(path, %{text: "  line\n", expected_revision: 0}) |> json_response(200)
    assert saved["draft"]["text"] == "  line\n"
    assert saved["draft"]["revision"] == 1
    assert is_binary(saved["draft"]["updated_at"])
    assert conn |> get(path) |> json_response(200) == saved
    after_chat = Ash.get!(Chat, chat.id, actor: actor)
    assert after_chat.updated_at == before_chat.updated_at
    assert after_chat.last_message_id == before_chat.last_message_id
    assert %{has_draft: true, draft_updated_at: _} = ChatDraft.load_many([chat], actor)[chat.id]
  end

  test "stale writes and stale first writes cannot replace newer text or cleared drafts", %{
    conn: conn
  } do
    %{user: actor} = fixture = user_fixture()
    conn = sign_in_conn(conn, fixture)
    chat = create_chat!(actor)
    path = "/api/bff/chat-drafts/#{chat.id}"

    assert %{"draft" => %{"revision" => 0}} =
             conn |> put(path, %{text: "old", expected_revision: 8}) |> json_response(409)

    saved = conn |> put(path, %{text: "phone", expected_revision: 0}) |> json_response(200)

    assert conn |> put(path, %{text: "laptop", expected_revision: 0}) |> json_response(409) ==
             saved

    assert %{"draft" => %{"revision" => 2, "text" => ""}} =
             conn |> put(path, %{text: "", expected_revision: 1}) |> json_response(200)

    assert %{"draft" => %{"revision" => 2, "text" => ""}} =
             conn |> put(path, %{text: "old", expected_revision: 1}) |> json_response(409)

    assert ChatDraft.load_many([chat], actor) == %{}
    assert ChatDraft.list_marker(actor) == %{row_count: 1, revision_sum: 2}
  end

  test "drafts require authentication and never expose another owner's text", %{conn: conn} do
    %{user: actor} = fixture = user_fixture()
    %{user: other} = other_fixture = user_fixture()
    chat = create_chat!(actor)
    path = "/api/bff/chat-drafts/#{chat.id}"
    assert conn |> get(path) |> json_response(401)
    owner_conn = sign_in_conn(conn, fixture)
    assert owner_conn |> put(path, %{text: "private", expected_revision: 0}) |> json_response(200)
    other_conn = sign_in_conn(build_conn(), other_fixture)
    assert other_conn |> get(path) |> json_response(404)

    assert other_conn
           |> put(path, %{text: "overwrite", expected_revision: 1})
           |> json_response(404)

    assert ChatDraft.load_many([chat], other) == %{}

    assert {:ok, %{error: :not_found}} =
             ChatDraft.save(chat.id, %{"text" => "direct", "expected_revision" => 1}, other)
  end

  test "read-only shared access does not expose or allow composer drafts", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: viewer} = viewer_fixture = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, viewer]})
    bot = create_bot!(owner)
    configuration = create_configuration!(owner)
    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)
    chat = create_chat!(owner, bot_id: bot.id, llm_configuration_id: configuration.id)
    share_chat!(owner, chat, group)

    assert {:ok, _} =
             ChatDraft.save(chat.id, %{"text" => "private", "expected_revision" => 0}, owner)

    conn = sign_in_conn(conn, viewer_fixture)
    assert conn |> get("/api/bff/chat-state/#{chat.id}") |> json_response(200)
    assert conn |> get("/api/bff/chat-drafts/#{chat.id}") |> json_response(404)

    assert conn
           |> put("/api/bff/chat-drafts/#{chat.id}", %{text: "viewer", expected_revision: 0})
           |> json_response(404)

    assert ChatDraft.load_many([chat], viewer) == %{}
  end

  test "invalid revisions and invalid text do not create drafts", %{conn: conn} do
    %{user: actor} = fixture = user_fixture()
    conn = sign_in_conn(conn, fixture)
    chat = create_chat!(actor)
    path = "/api/bff/chat-drafts/#{chat.id}"

    for attrs <- [
          %{text: "x", expected_revision: -1},
          %{text: "x", expected_revision: "0"},
          %{text: nil, expected_revision: 0},
          %{text: String.duplicate("x", 1_048_577), expected_revision: 0}
        ] do
      assert conn |> put(path, attrs) |> json_response(422)
    end

    assert %{"draft" => %{"revision" => 0}} = conn |> get(path) |> json_response(200)
  end

  test "successful saves publish only private version invalidations", %{conn: conn} do
    %{user: actor} = fixture = user_fixture()
    %{user: other} = user_fixture()
    chat = create_chat!(actor)
    other_chat = create_chat!(other)
    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, ReadStateEvents.topic(actor.id))

    assert {:ok, _} =
             ChatDraft.save(other_chat.id, %{"text" => "secret", "expected_revision" => 0}, other)

    refute_received {:chat_draft_changed, _, _}
    conn = sign_in_conn(conn, fixture)
    path = "/api/bff/chat-drafts/#{chat.id}"
    assert conn |> put(path, %{text: "mine", expected_revision: 0}) |> json_response(200)
    chat_id = chat.id
    assert_receive {:chat_draft_changed, ^chat_id, 1}
    assert conn |> put(path, %{text: "old", expected_revision: 0}) |> json_response(409)
    refute_received {:chat_draft_changed, _, _}
  end

  test "consumption requires both exact text and version and retains a tombstone" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)

    assert {:ok, _} =
             ChatDraft.save(chat.id, %{"text" => "submitted", "expected_revision" => 0}, actor)

    refute ChatDraft.consume(chat.id, "different", 1, actor)

    assert {:ok, _} =
             ChatDraft.save(chat.id, %{"text" => "continued", "expected_revision" => 1}, actor)

    refute ChatDraft.consume(chat.id, "submitted", 1, actor)
    assert {:ok, %{text: "continued", revision: 2}} = ChatDraft.get(chat.id, actor)
    assert ChatDraft.consume(chat.id, "continued", 2, actor)
    assert {:ok, %{text: "", revision: 3}} = ChatDraft.get(chat.id, actor)
    refute ChatDraft.consume(chat.id, "continued", 2, actor)
  end

  test "consumption rolls back with a rejected acceptance transaction" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)

    assert {:ok, _} =
             ChatDraft.save(chat.id, %{"text" => "keep", "expected_revision" => 0}, actor)

    assert {:error, :rejected} =
             IntellectualClub.Repo.transaction(fn ->
               assert ChatDraft.consume(chat.id, "keep", 1, actor)
               IntellectualClub.Repo.rollback(:rejected)
             end)

    assert {:ok, %{text: "keep", revision: 1}} = ChatDraft.get(chat.id, actor)
  end

  test "SSE exposes draft revision but never draft text", %{conn: conn} do
    fixture = user_fixture()
    put_app_env(:chat_events_stream_ttl_ms, 5)
    put_app_env(:chat_events_heartbeat_ms, 1)
    send(self(), {:chat_draft_changed, 123, 4})

    conn =
      conn
      |> sign_in_conn(fixture)
      |> put_req_header("accept", "text/event-stream")
      |> get("/api/bff/chat-events")

    assert conn.status == 200
    assert conn.resp_body =~ "event: chat_draft_changed"
    assert conn.resp_body =~ ~s("chat_id":123)
    assert conn.resp_body =~ ~s("revision":4)
    refute conn.resp_body =~ "text"
  end
end
