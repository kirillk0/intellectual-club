defmodule IntellectualClub.Generation.SupervisorTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.Worker

  defmodule BlockingAdapter do
    @moduledoc false

    def stream_generate(%{context: context}, _emit) do
      send(context.test_pid, {:adapter_started, context.message_id})
      Process.sleep(:infinity)
    end
  end

  test "canceling a parent generation cancels active subagent descendant generations" do
    %{user: actor} = user_fixture()
    test_pid = self()

    parent_chat = create_chat!(actor)
    parent_message = start_blocking_generation!(parent_chat, actor, test_pid, "Parent")

    fork_chat =
      create_chat!(actor, %{
        note: "Fork child",
        parent_chat_id: parent_chat.id,
        parent_message_id: parent_message.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    fork_message = start_blocking_generation!(fork_chat, actor, test_pid, "Fork")

    handoff_chat =
      create_chat!(actor, %{
        note: "Handoff child",
        parent_chat_id: fork_chat.id,
        parent_message_id: fork_message.id,
        parent_relation_kind: :handoff,
        subagent: true
      })

    handoff_message = start_blocking_generation!(handoff_chat, actor, test_pid, "Handoff")

    parent_message_id = parent_message.id
    fork_message_id = fork_message.id
    handoff_message_id = handoff_message.id

    assert_receive {:adapter_started, ^parent_message_id}, 1_000
    assert_receive {:adapter_started, ^fork_message_id}, 1_000
    assert_receive {:adapter_started, ^handoff_message_id}, 1_000

    assert :ok = GenerationSupervisor.cancel_generation(parent_message.id)

    assert wait_for_status!(parent_message.id, actor, :canceled).status == :canceled
    assert wait_for_status!(fork_message.id, actor, :canceled).status == :canceled
    assert wait_for_status!(handoff_message.id, actor, :canceled).status == :canceled

    assert GenerationSupervisor.get_generation_state(parent_message.id) == :not_found
    assert GenerationSupervisor.get_generation_state(fork_message.id) == :not_found
    assert GenerationSupervisor.get_generation_state(handoff_message.id) == :not_found
  end

  defp create_chat!(actor, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      Map.merge(%{note: ""}, attrs),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp start_blocking_generation!(%Chat{} = chat, actor, test_pid, prompt) do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, prompt, actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => prompt}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: assistant_message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: BlockingAdapter,
      request_payload: raw_request,
      timeout_ms: 1_000,
      chunk_delay_ms: 0,
      test_pid: test_pid
    }

    {:ok, _pid} = Worker.start_link(%{context: context})
    assistant_message
  end

  defp wait_for_status!(message_id, actor, wanted_status) do
    deadline = System.monotonic_time(:millisecond) + 4_000
    do_wait_for_status!(message_id, actor, wanted_status, deadline)
  end

  defp do_wait_for_status!(message_id, actor, wanted_status, deadline) do
    message = Ash.get!(ChatMessage, message_id, actor: actor)

    if message.status == wanted_status do
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_status!(message_id, actor, wanted_status, deadline)
      else
        flunk("Message #{message_id} did not reach #{inspect(wanted_status)}")
      end
    end
  end
end
