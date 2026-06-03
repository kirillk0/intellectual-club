defmodule IntellectualClub.Generation.OrphanedRecoveryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  test "recover_orphaned_generations restarts generating message from the last step" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Recover orphaned", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    old_step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: generating_message.id,
          sequence: 1,
          status: :waiting_provider,
          raw_request: %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "stream" => true
          },
          raw_response: nil,
          response_final: false
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    message = wait_for_status!(generating_message.id, actor, [:done], 4_000)

    assert {:error, _} = Ash.get(ChatMessageStep, old_step.id, actor: actor)

    final_step =
      message.steps
      |> List.wrap()
      |> Enum.max_by(& &1.sequence)

    assert final_step.sequence == 1
    assert final_step.id != old_step.id
  end

  defp wait_for_status!(message_id, actor, wanted, timeout_ms)
       when is_integer(message_id) and is_list(wanted) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_status(message_id, actor, wanted, deadline)
  end

  defp do_wait_for_status(message_id, actor, wanted, deadline) do
    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    if message.status in wanted do
      wait_for_generation_worker_to_stop!(message_id)
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_status(message_id, actor, wanted, deadline)
      else
        flunk("Message did not reach expected status")
      end
    end
  end

  defp wait_for_generation_worker_to_stop!(message_id) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_for_generation_worker_to_stop!(message_id, deadline)
  end

  defp do_wait_for_generation_worker_to_stop!(message_id, deadline) do
    if GenerationSupervisor.get_generation_state(message_id) == :not_found do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_generation_worker_to_stop!(message_id, deadline)
      else
        flunk("Generation worker did not stop before timeout")
      end
    end
  end
end
