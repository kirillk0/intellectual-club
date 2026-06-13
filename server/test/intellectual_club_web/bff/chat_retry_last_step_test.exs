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

  test "POST /api/bff/chat-messages/:message_id/steps/:step_id/retry-from-step retries a done message from an earlier step",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Retry from done step")

    {assistant_message, [step_1, step_2, step_3]} =
      create_retryable_assistant_message_with_steps!(chat, actor, :done, "hello", 3)

    conn =
      post(
        conn,
        ~p"/api/bff/chat-messages/#{assistant_message.id}/steps/#{step_2.id}/retry-from-step",
        %{}
      )

    payload = json_response(conn, 200)

    assert get_in(payload, ["generation", "message_id"]) == assistant_message.id
    assert {:ok, _step} = Ash.get(ChatMessageStep, step_1.id, actor: actor)
    assert {:error, _error} = Ash.get(ChatMessageStep, step_2.id, actor: actor)
    assert {:error, _error} = Ash.get(ChatMessageStep, step_3.id, actor: actor)

    retried = find_message(payload["branch"] || [], assistant_message.id)
    assert retried["status"] in ["generating", "done"]

    wait_for_generation_to_finish(conn, assistant_message.id)

    message =
      Ash.get!(ChatMessage, assistant_message.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    [preserved_step, retried_step] = Enum.sort_by(message.steps || [], & &1.sequence)

    assert preserved_step.id == step_1.id
    assert retried_step.sequence == 2
    assert retried_step.id != step_2.id
  end

  test "POST /api/bff/chat-messages/:message_id/steps/:step_id/retry-from-step rejects generating messages",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Retry from generating step")

    {assistant_message, [step]} =
      create_retryable_assistant_message_with_steps!(chat, actor, :generating, "hello", 1)

    conn =
      post(
        conn,
        ~p"/api/bff/chat-messages/#{assistant_message.id}/steps/#{step.id}/retry-from-step",
        %{}
      )

    payload = json_response(conn, 422)

    assert payload["error"] == "Retry from this step is available after generation stops."
    assert {:ok, _step} = Ash.get(ChatMessageStep, step.id, actor: actor)

    message = Ash.get!(ChatMessage, assistant_message.id, actor: actor)
    assert message.status == :generating
  end

  test "POST /api/bff/chat-messages/:message_id/steps/:step_id/retry-from-step returns 404 for a step from another message",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Retry wrong step")

    {assistant_message, [_step_1, _step_2]} =
      create_retryable_assistant_message_with_steps!(chat, actor, :done, "hello", 2)

    {_other_message, [other_step]} =
      create_retryable_assistant_message_with_steps!(chat, actor, :done, "another", 1)

    conn =
      post(
        conn,
        ~p"/api/bff/chat-messages/#{assistant_message.id}/steps/#{other_step.id}/retry-from-step",
        %{}
      )

    payload = json_response(conn, 404)
    assert payload["error"] == "Step not found"
  end

  defp create_chat!(actor, title) do
    Chat
    |> Ash.Changeset.for_create(:create, %{title: title, note: ""}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_retryable_assistant_message!(chat, actor, status, prompt) do
    {assistant_message, [old_step]} =
      create_retryable_assistant_message_with_steps!(chat, actor, status, prompt, 1)

    {assistant_message, old_step}
  end

  defp create_retryable_assistant_message_with_steps!(chat, actor, status, prompt, step_count)
       when is_integer(step_count) and step_count > 0 do
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

    steps =
      Enum.map(1..step_count, fn sequence ->
        ChatMessageStep
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_id: assistant_message.id,
            sequence: sequence,
            status: retryable_step_status(status),
            raw_request: %{
              "model" => "demo-model",
              "messages" => [
                %{"role" => "user", "content" => "#{prompt} step #{sequence}"}
              ],
              "stream" => true
            },
            raw_response: %{},
            response_final: status == :done and sequence == step_count
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)
      end)

    {assistant_message, steps}
  end

  defp retryable_step_status(:generating), do: :waiting_provider
  defp retryable_step_status(status), do: status

  defp find_message(branch, message_id) do
    Enum.find(branch, fn message -> message["id"] == message_id end) || %{}
  end
end
