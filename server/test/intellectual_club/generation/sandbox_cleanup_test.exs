defmodule IntellectualClub.Generation.SandboxCleanupTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.SandboxCleanup
  alias IntellectualClub.Test.AsyncPersistenceAdapter

  @persistence_start [:intellectual_club, :generation, :persistence, :start]
  @repo_query [:intellectual_club, :repo, :query]

  test "drain preserves SQL ownership through an active writer and the original lease cleanup ACK" do
    %{actor: actor, message: message, context: context} = fixture()
    manager = Process.whereis(Lease)
    manager_monitor = Process.monitor(manager)
    gate = make_ref()
    handler = {__MODULE__, gate}
    tasks = start_supervised!({Task.Supervisor, []})

    :ok =
      :telemetry.attach_many(
        handler,
        [@persistence_start, @repo_query],
        &__MODULE__.sql_barrier/4,
        {self(), message.id, manager, gate}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, _context} = GenerationSupervisor.start_prepared_context(context)
    worker = GenerationSupervisor.generation_worker_pid(message.id)
    assert_receive {:writer_checked_out, writer}, 5_000
    writer_monitor = Process.monitor(writer)
    :erlang.trace(worker, true, [:receive])

    try do
      drain = Task.Supervisor.async_nolink(tasks, &SandboxCleanup.stop_background_tasks!/0)

      assert_receive {:trace, ^worker, :receive, {:"$gen_cast", :cancel}}, 5_000
      state = :sys.get_state(worker)
      assert state.cancel_requested?
      assert state.persistence_op.task.pid == writer
      assert Task.yield(drain, 0) == nil
      send(writer, {gate, :continue})

      assert_receive {:cleanup_checked_out, cleanup}, 5_000

      try do
        state = :sys.get_state(manager)
        assert map_size(state.cleanups) == 1
        assert Map.has_key?(state.leases, message.id)
        assert {:error, :already_running} = Lease.reserve(message.id)
        assert Task.yield(drain, 0) == nil
      after
        send(cleanup, {gate, :continue})
      end

      assert :ok = Task.await(drain, 5_000)
      assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 5_000
      assert Process.whereis(Lease) == manager
      assert %{leases: leases, cleanups: cleanups} = :sys.get_state(manager)
      assert leases == %{} and cleanups == %{}
      refute_received {:DOWN, ^manager_monitor, :process, ^manager, _}
      assert Ash.get!(ChatMessage, message.id, actor: actor).generation_fence_token == nil
    after
      send(writer, {gate, :continue})
      :telemetry.detach(handler)
      Process.demonitor(manager_monitor, [:flush])
    end
  end

  # Holding an actual Ash transaction reproduces a borrower being interrupted
  # while it owns the shared connection, not merely a task waiting outside SQL.
  def sql_barrier(
        @persistence_start,
        _measurements,
        %{kind: :initialize, message_id: message_id},
        {test, message_id, _manager, gate}
      ) do
    Ash.transaction(ChatMessage, fn ->
      Ash.get!(ChatMessage, message_id, authorize?: false)
      await_test_release(test, gate, :writer_checked_out)
    end)
  end

  def sql_barrier(@repo_query, _measurements, %{query: query}, {test, _id, manager, gate}) do
    if manager in List.wrap(Process.get(:"$callers")) and
         String.contains?(query, "FOR NO KEY UPDATE") do
      await_test_release(test, gate, :cleanup_checked_out)
    end
  end

  def sql_barrier(_event, _measurements, _metadata, _config), do: :ok

  defp await_test_release(test, gate, event) do
    monitor = Process.monitor(test)
    send(test, {event, self()})

    try do
      receive do
        {^gate, :continue} -> :ok
        {:DOWN, ^monitor, :process, ^test, _reason} -> :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp fixture do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(:create_generating_assistant, %{chat_id: chat.id}, actor: actor)
      |> Ash.create!(actor: actor)

    request = %{"model" => "test", "messages" => [], "stream" => true}
    step_id = Persistence.ensure_step_started!(message.id, request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      step_id: step_id,
      adapter_module: AsyncPersistenceAdapter,
      request_payload: request,
      timeout_ms: 5_000,
      chunk_delay_ms: 0,
      test_pid: self(),
      tool_instances_by_alias: %{},
      tools_payload: []
    }

    %{actor: actor, message: message, context: context}
  end
end
