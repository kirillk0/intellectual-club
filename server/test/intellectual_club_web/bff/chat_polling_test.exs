defmodule IntellectualClubWeb.Bff.ChatPollingTest do
  @moduledoc """
  Polling-based streaming tests for the SPA BFF.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  test "poll returns current_step snapshot while generation is running", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{title: "Polling chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    prompt =
      1..60
      |> Enum.map(&"word#{&1}")
      |> Enum.join(" ")

    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, prompt, actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 5)

    # Allow a few chunks to accumulate.
    Process.sleep(40)

    {payload, answer1} = poll_answer_text(conn, context.message_id)

    assert payload["runtime"] == true
    assert payload["status"] == "generating"
    assert payload["finished_at"] == nil
    assert is_map(payload["current_step"])
    assert payload["current_step"]["finished_at"] == nil
    assert is_binary(answer1)

    Process.sleep(40)

    {_payload, answer2} = poll_answer_text(conn, context.message_id)

    assert byte_size(answer2) >= byte_size(answer1)

    final_payload = wait_for_generation_to_finish(conn, context.message_id)

    assert is_binary(final_payload["finished_at"])
  end

  test "raw request is persisted to step immediately and readable while generation is running", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{title: "Step raw chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 5)

    Process.sleep(10)

    state =
      conn
      |> get("/api/bff/chats/#{chat.id}/state")
      |> json_response(200)

    message =
      Enum.find(state["branch"] || [], fn msg -> msg["id"] == context.message_id end) || %{}

    step =
      case message do
        %{"steps" => [first | _rest]} when is_map(first) -> first
        _ -> %{}
      end

    assert is_integer(step["id"])
    assert step["id"] > 0

    payload =
      conn
      |> get("/api/bff/chat-messages/#{context.message_id}/steps/#{step["id"]}/raw?kind=request")
      |> json_response(200)

    assert is_map(payload["step"])
    assert is_map(payload["step"]["raw_request"])

    wait_for_generation_to_finish(conn, context.message_id)
  end

  test "poll fallback returns persisted steps after worker exits", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Polling fallback chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 1)

    wait_for_generation_to_finish(conn, context.message_id)

    payload = wait_for_poll_fallback(conn, context.message_id)

    assert payload["runtime"] == false
    assert payload["status"] in ["done", "canceled", "error"]
    assert is_binary(payload["finished_at"])
    assert is_integer(payload["token_count"])
    assert is_list(payload["steps"])
    assert is_map(payload["current_step"])
    assert is_binary(payload["current_step"]["finished_at"])

    {_payload, answer} = poll_answer_text(conn, context.message_id)
    assert String.trim(answer) != ""
  end

  test "poll fallback resumes orphaned generating message instead of canceling it", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Orphaned poll fallback", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _old_step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: generating_message.id,
          sequence: 1,
          status: :waiting_provider,
          raw_request: %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "hello"}],
            "stream" => true
          },
          raw_response: nil,
          response_final: false
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    payload =
      conn
      |> get("/api/bff/chat-messages/#{generating_message.id}/poll")
      |> json_response(200)

    assert payload["status"] in ["generating", "done"]
    refute payload["status"] == "canceled"

    wait_for_generation_to_finish(conn, generating_message.id)

    final_payload =
      conn
      |> get("/api/bff/chat-messages/#{generating_message.id}/poll")
      |> json_response(200)

    assert final_payload["status"] == "done"
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
      payload
    else
      Process.sleep(20)
      wait_for_generation_to_finish(conn, message_id, attempts_left - 1)
    end
  end

  defp wait_for_poll_fallback(conn, message_id, attempts_left \\ 200)

  defp wait_for_poll_fallback(_conn, _message_id, 0) do
    flunk("Polling fallback did not activate within timeout")
  end

  defp wait_for_poll_fallback(conn, message_id, attempts_left) do
    payload =
      conn
      |> get("/api/bff/chat-messages/#{message_id}/poll")
      |> json_response(200)

    if payload["runtime"] == false do
      payload
    else
      Process.sleep(10)
      wait_for_poll_fallback(conn, message_id, attempts_left - 1)
    end
  end

  defp poll_answer_text(conn, message_id) do
    payload =
      conn
      |> get("/api/bff/chat-messages/#{message_id}/poll")
      |> json_response(200)

    step = Map.get(payload, "current_step") || %{}
    items = Map.get(step, "items") || []

    answer_item = Enum.find(items, fn item -> Map.get(item, "type") == "answer" end) || %{}
    contents = Map.get(answer_item, "contents") || []

    text =
      contents
      |> Enum.filter(fn content -> Map.get(content, "kind") == "text" end)
      |> Enum.sort_by(fn content -> Map.get(content, "sequence") || 0 end)
      |> Enum.map_join("", fn content -> Map.get(content, "content_text") || "" end)

    {payload, text}
  end
end
