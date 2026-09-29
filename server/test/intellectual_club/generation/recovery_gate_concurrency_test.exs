defmodule IntellectualClub.Generation.RecoveryGateConcurrencyTest do
  use IntellectualClub.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep}
  alias IntellectualClub.Generation.RecoveryGate

  require Ash.Query

  @tag sandbox: false
  test "concurrent connections reserve only one recovery attempt and one cooldown" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
      |> Ash.create!(actor: actor)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Ash.destroy!(Ash.get!(Chat, chat.id, actor: actor), actor: actor)

        actor
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(authorize?: false)
      end)
    end)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(:create_generating_assistant, %{chat_id: chat.id}, actor: actor)
      |> Ash.create!(actor: actor)

    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_id: message.id, sequence: 1, status: :waiting_provider, raw_request: %{}},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    caller = self()
    now = ~U[2030-01-01 00:00:00.000000Z]

    tasks =
      for index <- 1..2 do
        pid =
          start_supervised!(%{
            id: {__MODULE__, index},
            start:
              {Task, :start_link,
               [
                 fn ->
                   result =
                     Sandbox.unboxed_run(Repo, fn ->
                       # Both transactions hold separate checked-out connections
                       # before either is allowed to attempt the row locks.
                       Ash.transaction([Chat, ChatMessage], fn ->
                         send(caller, {:ready, self()})

                         receive do
                           :admit -> :ok
                         after
                           5_000 -> flunk("Admission barrier timed out")
                         end

                         RecoveryGate.admit(message.id, nil, actor, now: now, jitter_ratio: 0)
                       end)
                     end)

                   send(caller, {:result, self(), result})
                 end
               ]},
            restart: :temporary
          })

        {pid, Process.monitor(pid)}
      end

    for {pid, _monitor} <- tasks, do: assert_receive({:ready, ^pid}, 5_000)
    for {pid, _monitor} <- tasks, do: send(pid, :admit)

    results =
      for {pid, monitor} <- tasks do
        assert_receive {:result, ^pid, {:ok, result}}, 5_000
        assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 5_000
        assert reason in [:normal, :noproc]
        result
      end

    retry_at = DateTime.add(now, 250, :millisecond)
    assert Enum.count(results, &(&1 == {:ok, :admitted})) == 1
    assert Enum.count(results, &(&1 == {:error, {:recovery_deferred, retry_at}})) == 1

    persisted =
      ChatMessage
      |> Ash.Query.filter(id == ^message.id)
      |> Ash.Query.select([:generation_recovery])
      |> Ash.read_one!(actor: actor)

    assert persisted.generation_recovery["attempts"] == 1
    assert persisted.generation_recovery["next_retry_at"] == DateTime.to_iso8601(retry_at)
  end
end
