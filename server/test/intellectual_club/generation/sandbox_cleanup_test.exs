defmodule IntellectualClub.Generation.SandboxCleanupTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.SandboxCleanup
  alias IntellectualClub.Test.AsyncPersistenceAdapter

  @persistence_start [:intellectual_club, :generation, :persistence, :start]
  @repo_query [:intellectual_club, :repo, :query]

  test "cancel interrupts an external tool but drains its sibling SQL transaction before releasing the lease" do
    %{actor: actor, message: message, context: context} = fixture()
    tasks = start_supervised!({Task.Supervisor, []})
    test = self()

    server =
      start_supervised!(
        {Bandit,
         plug:
           {IntellectualClub.TestSupport.WebSearchServer,
            handler: fn _path, _payload -> {:wait, test} end, test_pid: test},
         scheme: :http,
         port: 0}
      )

    {:ok, {_host, port}} = ThousandIsland.listener_info(server)

    tool = %IntellectualClub.Tools.ToolInstance{
      type: "native-web-search",
      config: %{
        "providers" => ["brave"],
        "provider_options" => %{"brave" => %{"api_base_url" => "http://127.0.0.1:#{port}/brave"}}
      },
      secrets: %{"brave_api_key" => "test-key"}
    }

    context =
      Map.merge(context, %{
        tool_instances_by_alias: %{"web" => tool},
        test_tool_calls: [
          %{name: "missing__run", args: %{}},
          %{name: "web__web_search", args: %{"query" => "cancel while another tool writes"}}
        ]
      })

    manager = Process.whereis(Lease)
    manager_monitor = Process.monitor(manager)
    assert {:ok, _context} = GenerationSupervisor.start_prepared_context(context)
    worker = GenerationSupervisor.generation_worker_pid(message.id)
    worker_monitor = Process.monitor(worker)
    assert_receive {:provider_started, _, provider, _request}, 5_000

    gate = make_ref()
    handler = {__MODULE__, gate}

    :ok =
      :telemetry.attach(
        handler,
        @repo_query,
        &__MODULE__.tool_sql_barrier/4,
        {self(), worker, gate}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(provider, {:complete, :tools})
    assert_receive {:tool_checked_out, writer}, 5_000
    assert_receive {:waiting, request}, 5_000
    writer_monitor = Process.monitor(writer)

    {external, _phase} =
      Enum.find(:sys.get_state(worker).tool_executions, fn {_pid, {_ref, phase}} ->
        phase == :interruptible
      end)

    external_monitor = Process.monitor(external)
    :erlang.trace(worker, true, [:receive])

    try do
      cancel = Task.Supervisor.async_nolink(tasks, fn -> Worker.cancel_and_wait(worker) end)
      assert_receive {:trace, ^worker, :receive, {:"$gen_call", _, :cancel_and_wait}}, 5_000
      state = :sys.get_state(worker)
      assert state.cancel_requested?
      refute is_nil(state.tool_task)
      assert Task.yield(cancel, 0) == nil
      assert_receive {:DOWN, ^external_monitor, :process, ^external, :killed}, 5_000
      refute_received {:DOWN, ^writer_monitor, :process, ^writer, _}
      send(writer, {gate, :continue})

      assert :ok = Task.await(cancel, 5_000)
      assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 5_000
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 5_000
      assert :ok = SandboxCleanup.stop_background_tasks!()
      assert Process.whereis(Lease) == manager
      refute_received {:DOWN, ^manager_monitor, :process, ^manager, _}
      canceled = Ash.get!(ChatMessage, message.id, actor: actor)
      assert canceled.status == :canceled
      assert canceled.generation_fence_token == nil
      assert [_missing_external_call] = Persistence.list_missing_tool_calls!(context.step_id)
      assert [_saved_result] = Persistence.load_step_for_followup!(context.step_id).results
      refute_received {:provider_started, _, _, _}
    after
      send(request, :continue)
      send(writer, {gate, :continue})
      :telemetry.detach(handler)
      Process.demonitor(manager_monitor, [:flush])
    end
  end

  def tool_sql_barrier(@repo_query, _measurements, %{query: query}, {test, worker, gate}) do
    callers = List.wrap(Process.get(:"$callers"))

    if worker in callers and List.first(callers) != worker and
         String.contains?(query, "FOR NO KEY UPDATE") do
      await_test_release(test, gate, :tool_checked_out)
    end
  end

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
      max_tool_rounds: 5,
      test_pid: self(),
      tool_instances_by_alias: %{},
      tools_payload: []
    }

    %{actor: actor, message: message, context: context}
  end
end
