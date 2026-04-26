defmodule IntellectualClub.Generation.ContextBranchLoadTest do
  @moduledoc """
  Regression tests for generation context history loading.
  """

  use IntellectualClub.DataCase, async: false

  import ExUnit.CaptureLog

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Context

  test "build!/2 does not fetch raw step payloads from history branch" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "History branch load", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _root} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)
    {:ok, assistant} = Threads.add_message_to_end(chat, :assistant, "answer", actor: actor)

    _ =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: assistant.id,
          sequence: 2,
          raw_request: %{"blob" => String.duplicate("x", 1_000)},
          raw_response: %{"ok" => true}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    log =
      capture_log([level: :debug], fn ->
        Context.build!(chat.id, actor: actor)
      end)

    refute log =~ ~s(c0."raw_request")
    refute log =~ ~s(c0."raw_response")
  end
end
