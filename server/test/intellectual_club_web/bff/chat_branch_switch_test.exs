defmodule IntellectualClubWeb.Bff.ChatBranchSwitchTest do
  @moduledoc """
  Branch switching endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads

  test "POST /api/bff/chats/:id/switch-branch switches by explicit target_id", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{title: "Switch chat", note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)
    {:ok, a1} = Threads.add_message(chat, :assistant, "A", actor: actor, parent_id: root.id)
    {:ok, _a1_u} = Threads.add_message(chat, :user, "A.u", actor: actor, parent_id: a1.id)
    {:ok, b1} = Threads.add_message(chat, :assistant, "B", actor: actor, parent_id: root.id)
    {:ok, b1_u} = Threads.add_message(chat, :user, "B.u", actor: actor, parent_id: b1.id)

    {:ok, _branch} = Threads.activate_branch(chat.id, a1.id, actor)

    conn =
      post(conn, ~p"/api/bff/chats/#{chat.id}/switch-branch", %{
        "message_id" => a1.id,
        "target_id" => b1.id
      })

    payload = json_response(conn, 200)
    branch_ids = Enum.map(payload["branch"] || [], & &1["id"])

    assert branch_ids == [root.id, b1.id, b1_u.id]
  end
end
