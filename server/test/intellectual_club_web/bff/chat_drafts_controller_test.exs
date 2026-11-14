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

  describe "attachments" do
    alias IntellectualClub.Chat.{ChatDraftAttachment, QueuedMessages}
    alias IntellectualClub.Files
    alias IntellectualClubWeb.Bff.ChatAttachments

    test "both image variants survive reload and selection without changing the text revision", %{
      conn: conn
    } do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)
      {:ok, _} = ChatDraft.save(chat.id, %{"text" => "typing", "expected_revision" => 0}, actor)
      id = Ecto.UUID.generate()
      path = "/api/bff/chat-drafts/#{chat.id}/attachments/#{id}"

      assert %{"attachment" => %{"status" => "pending"}} =
               conn
               |> put(path, %{operation: "start", filename: "image.png"})
               |> json_response(200)

      original =
        create_chat_upload!(actor, chat.id, %{
          filename: "image.png",
          mime_type: "image/png",
          payload: "original"
        })

      compressed =
        create_chat_upload!(actor, chat.id, %{
          filename: "small.png",
          mime_type: "image/png",
          payload: "small"
        })

      params = %{
        operation: "finish",
        original_upload_id: original.external_id,
        compressed_upload_id: compressed.external_id,
        image: %{width: 4000, height: 3000, compressed_width: 2000, compressed_height: 1500}
      }

      saved = conn |> put(path, params) |> json_response(200)
      assert saved["attachment"]["revision"] == 1
      assert conn |> put(path, params) |> json_response(200) == saved
      assert conn |> get(saved["attachment"]["original"]["url"]) |> response(200) == "original"
      assert conn |> get(saved["attachment"]["compressed"]["url"]) |> response(200) == "small"

      assert %{"attachment" => %{"keep_original" => true, "revision" => 2}} =
               conn
               |> put(path, %{operation: "select", expected_revision: 1, keep_original: true})
               |> json_response(200)

      assert %{
               "attachments" => [
                 %{"keep_original" => true, "original" => %{}, "compressed" => %{}}
               ]
             } =
               conn |> get("/api/bff/chat-drafts/#{chat.id}/attachments") |> json_response(200)

      assert {:ok, %{text: "typing", revision: 1}} = ChatDraft.get(chat.id, actor)

      assert %{"attachment" => %{"keep_original" => true, "revision" => 2}} =
               conn
               |> put(path, %{operation: "select", expected_revision: 1, keep_original: false})
               |> json_response(200)
    end

    test "attachment-only drafts are listed and files are private to their owner", %{conn: conn} do
      %{user: actor} = owner = user_fixture()
      other = user_fixture()
      chat = create_chat!(actor)
      attachment = create_chat_draft_attachment!(actor, chat.id)
      assert %{has_draft: true} = ChatDraft.load_many([chat], actor)[chat.id]
      assert Ash.load!(chat, :personal_draft_updated_at, actor: actor).personal_draft_updated_at
      conn = sign_in_conn(conn, other)
      assert conn |> get(attachment.original.url) |> json_response(404)
      assert conn |> get("/api/bff/chat-drafts/#{chat.id}/attachments") |> json_response(404)

      assert conn
             |> delete("/api/bff/chat-drafts/#{chat.id}/attachments/#{attachment.id}")
             |> json_response(404)

      conn = sign_in_conn(build_conn(), owner)
      assert conn |> get(attachment.original.url) |> response(200) == "content"
    end

    test "deletion tombstones reject late registration and completed uploads" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      id = Ecto.UUID.generate()

      assert {:ok, %{attachment: %{status: :deleted}}} =
               ChatDraftAttachment.mutate(chat.id, id, :delete, %{}, actor)

      assert {:ok, %{attachment: %{status: :deleted}}} =
               ChatDraftAttachment.mutate(chat.id, id, :start, %{}, actor)

      assert {:ok, %{attachment: %{status: :deleted}}} =
               ChatDraftAttachment.mutate(chat.id, id, :finish, %{}, actor)

      assert {:ok, []} = ChatDraftAttachment.list(chat.id, actor)
      assert ChatDraft.load_many([chat], actor) == %{}
    end

    test "accepting a queue entry consumes only submitted attachments and keeps its selected bytes" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)

      selected =
        create_chat_draft_attachment!(actor, chat.id, %{
          payload: "original",
          compressed: "compressed"
        })

      later = create_chat_draft_attachment!(actor, chat.id, %{payload: "later"})
      specs = [%{"id" => selected.id, "revision" => selected.revision}]
      prepared = %{draft_attachments: specs}
      policy = %{allow_any_files: true, allow_images: true, max_file_size_bytes: 1000}

      assert {:ok, queued} =
               ChatAttachments.with_prepared_file_ids(chat.id, actor, policy, prepared, fn ids ->
                 QueuedMessages.enqueue_follow_up(
                   chat.id,
                   %{file_ids: ids, draft_attachments: specs},
                   actor
                 )
               end)

      queued = Ash.load!(queued, :contents, actor: actor)
      assert [content] = queued.contents
      assert {:ok, {_, "compressed"}} = Files.load_payload(content.file_id)
      assert {:ok, [%{id: remaining_id}]} = ChatDraftAttachment.list(chat.id, actor)
      assert remaining_id == later.id

      assert {:error, :not_found} =
               ChatDraftAttachment.load_file(chat.id, selected.id, "original", actor)
    end

    test "stale selection cannot be consumed and failed acceptance preserves both variants" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)

      attachment =
        create_chat_draft_attachment!(actor, chat.id, %{
          payload: "original",
          compressed: "compressed"
        })

      old_specs = [%{"id" => attachment.id, "revision" => attachment.revision}]

      {:ok, %{attachment: selected}} =
        ChatDraftAttachment.mutate(
          chat.id,
          attachment.id,
          :select,
          %{"expected_revision" => attachment.revision, "keep_original" => true},
          actor
        )

      policy = %{allow_any_files: true, allow_images: true, max_file_size_bytes: 1000}

      assert {:error, _} =
               ChatAttachments.with_prepared_file_ids(
                 chat.id,
                 actor,
                 policy,
                 %{draft_attachments: old_specs},
                 fn _ -> flunk("stale snapshot accepted") end
               )

      specs = [%{"id" => selected.id, "revision" => selected.revision}]

      assert {:error, :rejected} =
               ChatAttachments.with_prepared_file_ids(
                 chat.id,
                 actor,
                 policy,
                 %{draft_attachments: specs},
                 fn _ -> {:error, :rejected} end
               )

      assert {:error, :rejected} =
               IntellectualClub.Repo.transaction(fn ->
                 ChatDraft.consume(chat.id, "", nil, actor, specs)
                 IntellectualClub.Repo.rollback(:rejected)
               end)

      assert {:ok, {_, _}} =
               ChatDraftAttachment.load_file(chat.id, selected.id, "original", actor)

      assert {:ok, {_, _}} =
               ChatDraftAttachment.load_file(chat.id, selected.id, "compressed", actor)
    end

    test "chat deletion removes both logical draft files" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      attachment = create_chat_draft_attachment!(actor, chat.id, %{compressed: "smaller"})
      record = Ash.get!(ChatDraftAttachment, attachment.id, actor: actor)
      Ash.destroy!(chat, actor: actor)

      for id <- [record.original_file_id, record.compressed_file_id] do
        assert {:error, _} = Ash.get(Files.File, id, authorize?: false)
      end
    end
  end
end
