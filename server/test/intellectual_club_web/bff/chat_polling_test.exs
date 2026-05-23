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

  test "poll returns lean answer snapshot while generation is running", %{conn: conn} do
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
    refute Map.has_key?(payload, "current_step")
    refute Map.has_key?(payload, "steps")
    assert is_map(payload["content"])
    assert get_in(payload, ["working", "step_count"]) >= 1
    assert is_binary(answer1)

    open_payload =
      conn
      |> get("/api/bff/chat-messages/#{context.message_id}/poll?working_step_id=latest")
      |> json_response(200)

    assert is_map(get_in(open_payload, ["working_open", "step"]))
    assert get_in(open_payload, ["working_open", "step", "finished_at"]) == nil

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

    working =
      conn
      |> get("/api/bff/chat-messages/#{context.message_id}/working")
      |> json_response(200)

    step =
      case working do
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
    refute Map.has_key?(payload, "steps")
    refute Map.has_key?(payload, "current_step")
    assert get_in(payload, ["working", "step_count"]) >= 1
    assert is_binary(get_in(payload, ["usage", "latest_step", "finished_at"]))

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

    text =
      payload
      |> get_in(["content", "parts"])
      |> List.wrap()
      |> Enum.sort_by(fn content -> Map.get(content, "sequence") || 0 end)
      |> Enum.map_join("", fn content -> Map.get(content, "text") || "" end)

    {payload, text}
  end
end
