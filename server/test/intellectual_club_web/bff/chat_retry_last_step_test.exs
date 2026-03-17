defmodule IntellectualClubWeb.Bff.ChatRetryLastStepTest do
  @moduledoc """
  Retry-last-step endpoint tests for the SPA BFF.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads

  test "POST /api/bff/chat-messages/:id/retry-last-step retries assistant message in error state",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Retry error")

    {assistant_message, old_step} =
      create_retryable_assistant_message!(chat, actor, :error, "hello")

    conn = post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/retry-last-step", %{})
    payload = json_response(conn, 200)

    assert get_in(payload, ["generation", "message_id"]) == assistant_message.id
    assert {:error, _error} = Ash.get(ChatMessageStep, old_step.id, actor: actor)

    retried = find_message(payload["branch"] || [], assistant_message.id)
    assert retried["status"] in ["generating", "done"]

    wait_for_generation_to_finish(conn, assistant_message.id)
  end

  test "POST /api/bff/chat-messages/:id/retry-last-step retries assistant message in canceled state",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Retry canceled")

    {assistant_message, _old_step} =
      create_retryable_assistant_message!(chat, actor, :canceled, "hello")

    conn = post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/retry-last-step", %{})
    payload = json_response(conn, 200)

    assert get_in(payload, ["generation", "message_id"]) == assistant_message.id
    retried = find_message(payload["branch"] || [], assistant_message.id)
    assert retried["status"] in ["generating", "done"]

    wait_for_generation_to_finish(conn, assistant_message.id)
  end

  test "POST /api/bff/chat-messages/:id/retry-last-step rejects done messages", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Retry done")

    {assistant_message, _old_step} =
      create_retryable_assistant_message!(chat, actor, :done, "hello")

    conn = post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/retry-last-step", %{})
    payload = json_response(conn, 422)

    assert is_binary(payload["error"])
    assert String.contains?(payload["error"], "error or canceled")
  end

  defp create_chat!(actor, title) do
    Chat
    |> Ash.Changeset.for_create(:create, %{title: title, note: "", variables: %{}}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_retryable_assistant_message!(chat, actor, status, prompt) do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, prompt, actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: chat.id,
          role: :assistant,
          parent_id: user_message.id,
          status: status,
          error_detail: if(status == :error, do: "boom", else: nil),
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    old_step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: assistant_message.id,
          sequence: 1,
          status: status,
          raw_request: %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => prompt}],
            "stream" => true
          },
          raw_response: %{},
          response_final: false
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {assistant_message, old_step}
  end

  defp wait_for_generation_to_finish(conn, message_id, attempts_left \\ 200)

  defp wait_for_generation_to_finish(_conn, _message_id, 0) do
    flunk("Generation did not finish within timeout")
  end

  defp wait_for_generation_to_finish(conn, message_id, attempts_left) do
    payload =
      conn
      |> get("/api/bff/chat-messages/#{message_id}/poll")
      |> json_response(200)

    if payload["status"] in ["done", "canceled", "error"] do
      :ok
    else
      Process.sleep(20)
      wait_for_generation_to_finish(conn, message_id, attempts_left - 1)
    end
  end

  defp find_message(branch, message_id) do
    Enum.find(branch, fn message -> message["id"] == message_id end) || %{}
  end
end
