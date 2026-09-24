defmodule IntellectualClub.Generation.RetryCleanupTransactionTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{Chat, ChatMessage, Threads}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  test "a step disappearing before cleanup preflight cannot publish a retry fence" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, _input} = Threads.add_message_to_end(chat, :user, "Reply briefly", actor: actor)

    {:ok, message} =
      Threads.add_message_to_end(chat, :assistant, "Original response", actor: actor)

    message = Ash.load!(message, :steps, actor: actor)
    step = hd(message.steps)

    step =
      step
      |> Ash.Changeset.for_update(
        :update,
        %{
          raw_request: %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Reply briefly"}],
            "stream" => true
          },
          response_final: true
        },
        actor: actor
      )
      |> Ash.update!(actor: actor)

    handler = {__MODULE__, make_ref()}
    caller = self()
    scope = {:steps, message.id, step.sequence}

    # Remove the already-read source at the exact preflight boundary. This
    # deterministic fault injection needs no timing race or provider process.
    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :linked_fork_cleanup, :plan],
        fn _, _, metadata, _ ->
          if self() == caller and metadata.scope == scope do
            Ash.destroy!(step, actor: actor)
            send(caller, :source_removed_before_retry_locks)
          end
        end,
        nil
      )

    try do
      assert {:error, :retry_step_not_found} =
               GenerationSupervisor.retry_from_step(message.id, step.id, actor: actor)

      assert_received :source_removed_before_retry_locks
      current = Ash.get!(ChatMessage, message.id, actor: actor)
      assert current.generation_fence_token == nil
      assert current.status == :done
      assert GenerationSupervisor.get_generation_state(message.id) == :not_found
    after
      :telemetry.detach(handler)
    end
  end
end
