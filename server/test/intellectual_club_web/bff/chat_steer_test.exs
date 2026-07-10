defmodule IntellectualClubWeb.Bff.ChatSteerTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads

  test "steer validates content and requires an active generation", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

    {:ok, assistant_message} =
      Threads.add_message(chat, :assistant, "Answer",
        actor: actor,
        parent_id: user_message.id
      )

    empty_conn =
      post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/steer", %{"content" => ""})

    assert %{"code" => "empty_steering"} = json_response(empty_conn, 422)

    inactive_conn =
      post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/steer", %{
        "content" => "Change direction"
      })

    assert %{"code" => "generation_not_active"} = json_response(inactive_conn, 409)
  end
end
