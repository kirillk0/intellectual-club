defmodule IntellectualClubWeb.Bff.ChatGenerateTest do
  @moduledoc """
  Generation endpoint regression tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads

  test "POST /api/bff/chat-generation/:id/generate keeps deleted-reply parent by default", %{
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

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

    {:ok, assistant_message} =
      Threads.add_message(chat, :assistant, "First answer",
        actor: actor,
        parent_id: user_message.id
      )

    conn = post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/delete")
    delete_payload = json_response(conn, 200)

    assert Enum.map(delete_payload["branch"] || [], & &1["id"]) == [user_message.id]

    conn = post(conn, ~p"/api/bff/chat-generation/#{chat.id}/generate", %{})
    payload = json_response(conn, 200)

    generation_id = get_in(payload, ["generation", "message_id"])
    assert is_integer(generation_id)

    branch = payload["branch"] || []
    generated = Enum.find(branch, &(&1["id"] == generation_id))

    assert is_map(generated)
    assert generated["parent_id"] == user_message.id
    assert Enum.map(branch, & &1["id"]) == [user_message.id, generation_id]

    wait_for_generation_to_finish(conn, generation_id)
  end

  test "POST /api/bff/chat-generation/:id/generate with explicit null parent creates root assistant branch",
       %{conn: conn} do
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

    {:ok, root_assistant} =
      Threads.add_message(chat, :assistant, "First root answer",
        actor: actor,
        parent_id: nil
      )

    conn = post(conn, ~p"/api/bff/chat-generation/#{chat.id}/generate", %{"parent_id" => nil})
    payload = json_response(conn, 200)

    generation_id = get_in(payload, ["generation", "message_id"])
    assert is_integer(generation_id)

    branch = payload["branch"] || []
    generated = Enum.find(branch, &(&1["id"] == generation_id))

    assert is_map(generated)
    assert generated["parent_id"] == nil
    assert Enum.map(branch, & &1["id"]) == [generation_id]
    refute Enum.any?(branch, &(&1["id"] == root_assistant.id))

    wait_for_generation_to_finish(conn, generation_id)
  end
end
