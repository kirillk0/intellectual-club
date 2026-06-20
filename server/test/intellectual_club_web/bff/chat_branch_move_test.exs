defmodule IntellectualClubWeb.Bff.ChatBranchMoveTest do
  @moduledoc """
  Move-branch-to-new-chat endpoint regression tests.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.MessageBookmark
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files

  require Ash.Query

  test "POST /api/bff/chat-branches/:id/move-to-new-chat moves the active sibling branch",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor, note: "Active move source")

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, active} =
      Threads.add_message(source, :assistant, "Active", actor: actor, parent_id: root.id)

    {:ok, active_child} =
      Threads.add_message(source, :user, "Active child", actor: actor, parent_id: active.id)

    {:ok, inactive} =
      Threads.add_message(source, :assistant, "Inactive", actor: actor, parent_id: root.id)

    {:ok, inactive_child} =
      Threads.add_message(source, :user, "Inactive child", actor: actor, parent_id: inactive.id)

    {:ok, _meta} = Threads.activate_branch(source.id, active_child.id, actor)

    payload =
      conn
      |> post(~p"/api/bff/chat-branches/#{source.id}/move-to-new-chat", %{
        "message_id" => active.id
      })
      |> json_response(200)

    target_id = get_in(payload, ["chat", "id"])
    assert is_integer(target_id)
    assert target_id != source.id
    assert get_in(payload, ["chat", "note"]) == "Active move source (branch)"

    assert Enum.map(payload["source_branch"], & &1["id"]) == [
             root.id,
             inactive.id,
             inactive_child.id
           ]

    target_branch = payload["branch"]

    assert Enum.map(target_branch, & &1["id"]) == [
             List.first(target_branch)["id"],
             active.id,
             active_child.id
           ]

    refute List.first(target_branch)["id"] == root.id

    assert Ash.get!(Chat, source.id, actor: actor).last_message_id == inactive_child.id
    assert Ash.get!(Chat, target_id, actor: actor).last_message_id == active_child.id

    assert Ash.get!(ChatMessage, active.id, actor: actor).chat_id == target_id
    assert Ash.get!(ChatMessage, active_child.id, actor: actor).chat_id == target_id
    assert Ash.get!(ChatMessage, inactive.id, actor: actor).chat_id == source.id
  end

  test "POST /api/bff/chat-branches/:id/move-to-new-chat moves an inactive branch without changing source active leaf",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor)

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, inactive} =
      Threads.add_message(source, :assistant, "Inactive", actor: actor, parent_id: root.id)

    {:ok, inactive_child} =
      Threads.add_message(source, :user, "Inactive child", actor: actor, parent_id: inactive.id)

    {:ok, active} =
      Threads.add_message(source, :assistant, "Active", actor: actor, parent_id: root.id)

    {:ok, active_child} =
      Threads.add_message(source, :user, "Active child", actor: actor, parent_id: active.id)

    {:ok, _meta} = Threads.activate_branch(source.id, active_child.id, actor)

    payload =
      conn
      |> post(~p"/api/bff/chat-branches/#{source.id}/move-to-new-chat", %{
        "message_id" => inactive.id
      })
      |> json_response(200)

    target_id = get_in(payload, ["chat", "id"])

    assert Enum.map(payload["source_branch"], & &1["id"]) == [root.id, active.id, active_child.id]

    target_branch = payload["branch"]

    assert Enum.map(target_branch, & &1["id"]) == [
             List.first(target_branch)["id"],
             inactive.id,
             inactive_child.id
           ]

    assert Ash.get!(Chat, source.id, actor: actor).last_message_id == active_child.id
    assert Ash.get!(Chat, target_id, actor: actor).last_message_id == inactive_child.id
  end

  test "POST /api/bff/chat-branches/:id/move-to-new-chat supports root sibling branches",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor)

    {:ok, moved_root} =
      Threads.add_message(source, :user, "Moved root", actor: actor, parent_id: nil)

    {:ok, moved_leaf} =
      Threads.add_message(source, :assistant, "Moved leaf",
        actor: actor,
        parent_id: moved_root.id
      )

    {:ok, kept_root} =
      Threads.add_message(source, :user, "Kept root", actor: actor, parent_id: nil)

    {:ok, kept_leaf} =
      Threads.add_message(source, :assistant, "Kept leaf", actor: actor, parent_id: kept_root.id)

    {:ok, _meta} = Threads.activate_branch(source.id, kept_leaf.id, actor)

    payload =
      conn
      |> post(~p"/api/bff/chat-branches/#{source.id}/move-to-new-chat", %{
        "message_id" => moved_root.id
      })
      |> json_response(200)

    target_id = get_in(payload, ["chat", "id"])

    assert Enum.map(payload["source_branch"], & &1["id"]) == [kept_root.id, kept_leaf.id]
    assert Enum.map(payload["branch"], & &1["id"]) == [moved_root.id, moved_leaf.id]
    assert Ash.get!(Chat, target_id, actor: actor).last_message_id == moved_leaf.id
  end

  test "POST /api/bff/chat-branches/:id/move-to-new-chat preserves moved subtree trace, files, bookmarks, and child chats",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor)
    {:ok, file} = Files.create_from_binary("move.txt", "text/plain", "move payload")

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    {:ok, moved} =
      Threads.add_message(source, :assistant, "",
        actor: actor,
        parent_id: root.id,
        contents: [
          %{kind: :text, content_text: "Moved"},
          %{kind: :media, file_id: file.id}
        ]
      )

    {:ok, moved_active_leaf} =
      Threads.add_message(source, :user, "Moved active leaf", actor: actor, parent_id: moved.id)

    {:ok, moved_inactive_leaf} =
      Threads.add_message(source, :user, "Moved inactive leaf", actor: actor, parent_id: moved.id)

    {:ok, kept} =
      Threads.add_message(source, :assistant, "Kept", actor: actor, parent_id: root.id)

    {:ok, _meta} = Threads.activate_branch(source.id, kept.id, actor)

    MessageBookmark
    |> Ash.Changeset.for_create(:create, %{chat_message_id: moved_active_leaf.id}, actor: actor)
    |> Ash.create!(actor: actor)

    {:ok, %{chat: handoff_child}} =
      Handoff.create_handoff_chat(source, actor, "Move summary",
        source_message_id: moved_active_leaf.id
      )

    moved_before =
      Ash.get!(ChatMessage, moved.id, actor: actor, load: [steps: [items: [:contents]]])

    moved_step_id = moved_before.steps |> List.first() |> Map.get(:id)
    media_file_id = moved_before.steps |> media_file_id_from_steps()

    payload =
      conn
      |> post(~p"/api/bff/chat-branches/#{source.id}/move-to-new-chat", %{
        "message_id" => moved.id
      })
      |> json_response(200)

    target_id = get_in(payload, ["chat", "id"])
    target_message_ids = target_id |> messages_for_chat!(actor) |> Enum.map(& &1.id)

    assert moved.id in target_message_ids
    assert moved_active_leaf.id in target_message_ids
    assert moved_inactive_leaf.id in target_message_ids
    assert kept.id not in target_message_ids

    moved_after =
      Ash.get!(ChatMessage, moved.id, actor: actor, load: [steps: [items: [:contents]]])

    assert moved_after.chat_id == target_id
    assert moved_after.steps |> List.first() |> Map.get(:id) == moved_step_id
    assert moved_after.steps |> media_file_id_from_steps() == media_file_id
    assert media_file_id == file.id

    assert [_bookmark] =
             MessageBookmark
             |> Ash.Query.filter(chat_message_id == ^moved_active_leaf.id)
             |> Ash.read!(actor: actor)

    handoff_child = Ash.get!(Chat, handoff_child.id, actor: actor)
    assert handoff_child.parent_chat_id == target_id
    assert handoff_child.parent_message_id == moved_active_leaf.id
  end

  test "POST /api/bff/chat-branches/:id/move-to-new-chat rejects invalid moves",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    source = create_chat!(actor)

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

    missing_payload =
      conn
      |> post(~p"/api/bff/chat-branches/#{source.id}/move-to-new-chat", %{})
      |> json_response(422)

    assert missing_payload["error"] == "message_id is required"

    no_sibling_payload =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> post(~p"/api/bff/chat-branches/#{source.id}/move-to-new-chat", %{
        "message_id" => root.id
      })
      |> json_response(422)

    assert no_sibling_payload["error"] == "Message does not have sibling branches."

    {:ok, moved} =
      Threads.add_message(source, :assistant, "Moved", actor: actor, parent_id: root.id)

    {:ok, _generating} =
      Threads.add_message(source, :user, "Generating",
        actor: actor,
        parent_id: moved.id,
        status: :generating
      )

    {:ok, _kept} =
      Threads.add_message(source, :assistant, "Kept", actor: actor, parent_id: root.id)

    generating_payload =
      build_conn()
      |> sign_in_conn(actor.username, password)
      |> post(~p"/api/bff/chat-branches/#{source.id}/move-to-new-chat", %{
        "message_id" => moved.id
      })
      |> json_response(422)

    assert generating_payload["error"] == "Cannot move a branch with a generating message."
  end

  test "POST /api/bff/chat-branches/:id/move-to-new-chat rejects non-owner",
       %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: other, password: password} = user_fixture()
    conn = sign_in_conn(conn, other.username, password)
    source = create_chat!(owner)

    {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: owner)

    {:ok, moved} =
      Threads.add_message(source, :assistant, "Moved", actor: owner, parent_id: root.id)

    {:ok, _kept} =
      Threads.add_message(source, :assistant, "Kept", actor: owner, parent_id: root.id)

    conn =
      post(conn, ~p"/api/bff/chat-branches/#{source.id}/move-to-new-chat", %{
        "message_id" => moved.id
      })

    assert response(conn, conn.status)
    assert conn.status in [403, 404]
  end

  defp create_chat!(actor, attrs \\ []) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, Map.merge(%{note: ""}, Map.new(attrs)),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp messages_for_chat!(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(steps: [items: [:contents]])
    |> Ash.read!(actor: actor)
  end

  defp media_file_id_from_steps(steps) do
    steps
    |> List.wrap()
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.flat_map(&(&1.contents || []))
    |> Enum.find_value(fn content ->
      if content.kind in [:media, "media"], do: content.file_id, else: nil
    end)
  end
end
