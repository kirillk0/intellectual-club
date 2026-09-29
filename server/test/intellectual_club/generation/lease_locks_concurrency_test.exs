defmodule IntellectualClub.Generation.LeaseLocksConcurrencyTest do
  use ExUnit.Case, async: false

  import IntellectualClub.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.QueuedMessage
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Lease.Capabilities
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Notifications.WebPushGenerationEvent
  alias IntellectualClub.Repo

  require Ash.Query

  @timeout 10_000

  setup do
    # Manager cleanup tasks use this committed connection. Every workload task
    # explicitly checks out a different, unboxed connection, never a shared
    # sandbox transaction. Backend identities and PostgreSQL's wait graph are
    # asserted at each conflict barrier.
    sql_owner = Sandbox.start_owner!(Repo, shared: true, sandbox: false)

    # The test process can die before async lease cleanup starts. Keep its SQL
    # owner alive through cleanup acknowledgments, including failing test paths.
    on_exit(fn ->
      try do
        IntellectualClub.DataCase.stop_background_test_tasks()
      after
        Sandbox.stop_owner(sql_owner)
      end
    end)

    %{user: actor} = user_fixture(%{username: "lease-locks-#{Ecto.UUID.generate()}"})
    source = message_fixture!(actor)
    unrelated = message_fixture!(actor)
    cleanup_backend = backend_pid!()

    on_exit(fn ->
      await_unleased!(source.message.id)
      await_unleased!(unrelated.message.id)

      Sandbox.unboxed_run(Repo, fn ->
        Chat
        |> Ash.Query.filter(owner_id == ^actor.id)
        |> Ash.Query.sort(id: :desc)
        |> Ash.read!(actor: actor)
        |> Enum.each(&Ash.destroy!(&1, actor: actor))

        actor
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(authorize?: false)
      end)
    end)

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :repo, :query],
        &__MODULE__.pause_after_commit/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{actor: actor, source: source, unrelated: unrelated, cleanup_backend: cleanup_backend}
  end

  test "coordinator chat fence does not form an FK cycle with a message-fenced writer", fixture do
    assert_chat_fk_cycle!(fixture, fn ->
      assert :active = QueueCoordinator.prepare_next(fixture.source.chat.id)
    end)
  end

  test "steering chat fence does not form an FK cycle with a message-fenced writer", fixture do
    assert_chat_fk_cycle!(fixture, fn ->
      assert {:ok, %QueuedMessage{kind: :steer}} =
               QueuedMessages.enqueue_steer(fixture.source.message.id, "Steer", fixture.actor)
    end)
  end

  test "message fences permit step and notification FK inserts but still serialize writers",
       %{source: source, actor: actor} do
    parent = self()

    holder =
      db_task!(fn ->
        Lease.with_token_fence(source.message.id, source.message.generation_fence_token, fn ->
          send(parent, {:message_locked, backend_pid!()})

          receive do
            {:await_writer, backend} -> await_blocked!(backend, backend_pid!())
          after
            @timeout -> flunk("Missing competing message writer")
          end
        end)
      end)

    assert_receive {:message_locked, holder_backend}, @timeout

    inserter =
      db_task!(fn ->
        assert backend_pid!() != holder_backend

        step =
          ChatMessageStep
          |> Ash.Changeset.for_create(
            :create,
            %{chat_message_id: source.message.id, sequence: 1, response_final: true},
            actor: actor
          )
          |> Ash.create!(actor: actor)

        event =
          WebPushGenerationEvent
          |> Ash.Changeset.for_create(
            :create,
            %{chat_message_id: source.message.id, status: :done, delivered_count: -1},
            actor: actor
          )
          |> Ash.create!(actor: actor)

        {step.id, event.id}
      end)

    # Both inserts must commit while the first writer still owns its row fence.
    assert {step_id, event_id} = finish!(inserter)
    assert is_integer(step_id) and is_integer(event_id)

    contender =
      db_task!(fn ->
        send(parent, {:contender_backend, backend_pid!()})

        Lease.with_token_fence(source.message.id, source.message.generation_fence_token, fn ->
          :serialized
        end)
      end)

    assert_receive {:contender_backend, contender_backend}, @timeout
    assert contender_backend != holder_backend
    send(holder.pid, {:await_writer, contender_backend})
    assert {:ok, :ok} = finish!(holder)
    assert {:ok, :serialized} = finish!(contender)
  end

  test "blocked release revokes capability without blocking unrelated lease operations",
       fixture do
    %{source: source, unrelated: unrelated, cleanup_backend: cleanup_backend} = fixture
    {owner, lease} = lease_owner!(source.message.id)
    holder = row_holder!(source.message.id)
    send(owner.pid, :release)
    assert_cleanup_blocked!(holder, cleanup_backend)

    refute Capabilities.active?(lease)
    assert {:error, :lease_lost} = Lease.with_fence(lease, fn -> flunk("released lease") end)
    assert {:error, :already_running} = Lease.reserve(source.message.id)
    assert {:ok, other} = Lease.reserve(unrelated.message.id)
    assert :ok = Lease.release(other)
    assert Lease.connection_pid() == :sys.get_state(lease.manager).connection

    send(holder.pid, :finish)
    assert {:ok, :ok} = finish!(holder)
    assert :ok = finish!(owner)

    assert Ash.get!(ChatMessage, source.message.id, actor: fixture.actor).generation_fence_token ==
             nil

    assert {:ok, successor} = Lease.acquire(source.message.id)
    assert successor.fence_token != lease.fence_token

    assert {:error, :lease_lost} =
             Lease.with_token_fence(source.message.id, lease.fence_token, fn -> :stale end)

    assert :ok = Lease.release(successor)
  end

  test "killed owners leave cleanup supervised and their advisory locks held until clear",
       fixture do
    %{source: source, unrelated: unrelated, cleanup_backend: cleanup_backend} = fixture
    {owner, lease} = lease_owner!(source.message.id)
    holder = row_holder!(source.message.id)
    Process.exit(owner.pid, :kill)
    assert_receive {:DOWN, ref, :process, pid, :killed}, @timeout
    assert ref == owner.monitor and pid == owner.pid
    assert_cleanup_blocked!(holder, cleanup_backend)

    assert Process.whereis(Lease) == lease.manager
    assert {:error, :already_running} = Lease.reserve(source.message.id)
    assert {:ok, other} = Lease.reserve(unrelated.message.id)
    assert :ok = Lease.release(other)

    send(holder.pid, :finish)
    assert {:ok, :ok} = finish!(holder)
    await_unleased!(source.message.id)

    assert Ash.get!(ChatMessage, source.message.id, actor: fixture.actor).generation_fence_token ==
             nil

    assert {:ok, successor} = Lease.acquire(source.message.id)
    assert :ok = Lease.release(successor)
  end

  test "owner death after commit but before registration clears the remembered claim token",
       %{source: source, actor: actor} do
    parent = self()

    owner =
      db_task!(fn ->
        assert {:ok, reservation} = Lease.reserve(source.message.id)
        Process.put({__MODULE__, :pause_commit}, parent)
        Lease.fence(reservation)
      end)

    assert_receive {:claim_committed, owner_pid}, @timeout
    assert owner_pid == owner.pid
    committed = Ash.get!(ChatMessage, source.message.id, actor: actor).generation_fence_token
    assert is_binary(committed)
    entry = :sys.get_state(Lease).leases[source.message.id]
    assert entry.fence_token == nil
    assert entry.claim_token == committed

    Process.exit(owner.pid, :kill)
    assert_receive {:DOWN, ref, :process, pid, :killed}, @timeout
    assert ref == owner.monitor and pid == owner.pid
    await_unleased!(source.message.id)
    assert Ash.get!(ChatMessage, source.message.id, actor: actor).generation_fence_token == nil

    assert {:error, :lease_lost} =
             Lease.with_token_fence(source.message.id, committed, fn -> :stale end)
  end

  test "late old-manager cleanup cannot clear a successor's committed token", %{source: source} do
    parent = self()
    {owner, old_lease} = lease_owner!(source.message.id)
    handler = {__MODULE__, :late_cleanup, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :repo, :query],
        &__MODULE__.pause_cleanup_before_lock/4,
        {parent, old_lease.manager}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(owner.pid, :release)
    assert_receive {:cleanup_before_lock, cleanup_pid}, @timeout
    cleanup_monitor = Process.monitor(cleanup_pid)
    manager_monitor = Process.monitor(old_lease.manager)
    connection = Lease.connection_pid()
    connection_monitor = Process.monitor(connection)
    Process.exit(old_lease.manager, :kill)
    assert_receive {:DOWN, ^manager_monitor, :process, _, :killed}, @timeout
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, _reason}, @timeout
    new_manager = await_new_manager!(old_lease.manager)
    assert new_manager != old_lease.manager
    refute Capabilities.active?(old_lease)

    successor =
      db_task!(fn ->
        lease = acquire_after_manager_restart!(source.message.id)
        send(parent, {:successor_fenced, lease})

        receive do
          :check_successor ->
            assert {:ok, :preserved} = Lease.with_fence(lease, fn -> :preserved end)
            assert :ok = Lease.release(lease)
        after
          @timeout -> flunk("Missing late-cleanup barrier")
        end
      end)

    assert_receive {:successor_fenced, lease}, @timeout
    assert lease.manager == new_manager
    assert lease.fence_token != old_lease.fence_token
    send(cleanup_pid, :continue_cleanup)
    assert_receive {:DOWN, ^cleanup_monitor, :process, ^cleanup_pid, :normal}, @timeout
    send(successor.pid, :check_successor)
    assert :ok = finish!(successor)
  end

  defp assert_chat_fk_cycle!(fixture, competing_operation) do
    parent = self()
    %{source: source, actor: actor} = fixture

    writer =
      db_task!(fn ->
        Lease.with_token_fence(source.message.id, source.message.generation_fence_token, fn ->
          send(parent, {:writer_backend, backend_pid!()})

          receive do
            {:await_coordinator, coordinator_backend} ->
              await_blocked!(coordinator_backend, backend_pid!())
          after
            @timeout -> flunk("Missing chat-fence competitor")
          end

          # This is a real Ash FK insert, not an explicit chat row lock. The
          # coordinator already holds chat and waits for our message fence.
          QueuedMessage
          |> Ash.Changeset.for_create(
            :enqueue,
            %{chat_id: source.chat.id, kind: :follow_up, anchor_message_id: source.message.id},
            actor: actor
          )
          |> Ash.create!(actor: actor)
        end)
      end)

    assert_receive {:writer_backend, writer_backend}, @timeout

    coordinator =
      db_task!(fn ->
        send(parent, {:coordinator_backend, backend_pid!()})
        competing_operation.()
      end)

    assert_receive {:coordinator_backend, coordinator_backend}, @timeout
    assert writer_backend != coordinator_backend
    send(writer.pid, {:await_coordinator, coordinator_backend})
    assert {:ok, %QueuedMessage{}} = finish!(writer)
    finish!(coordinator)
  end

  defp lease_owner!(message_id) do
    parent = self()

    owner =
      db_task!(fn ->
        assert {:ok, lease} = Lease.acquire(message_id)
        send(parent, {:lease_owned, lease})

        receive do
          :release -> Lease.release(lease)
        after
          @timeout -> flunk("Missing lease release request")
        end
      end)

    assert_receive {:lease_owned, lease}, @timeout
    {owner, lease}
  end

  defp row_holder!(message_id) do
    parent = self()

    holder =
      db_task!(fn ->
        Ash.transaction(ChatMessage, fn ->
          ChatMessage
          |> Ash.Query.filter(id == ^message_id)
          |> Ash.Query.lock("FOR NO KEY UPDATE")
          |> Ash.read_one!(authorize?: false)

          send(parent, {:holder_backend, backend_pid!()})

          receive do
            {:await_cleanup, cleanup_backend} ->
              assert cleanup_backend != backend_pid!()
              await_blocked!(cleanup_backend, backend_pid!())

              # A second database session cannot take the advisory lock while
              # cleanup is blocked. pg_try does not wait or change a held lock.
              case Repo.query!("SELECT pg_try_advisory_lock($1)", [Lease.lock_key(message_id)]) do
                %{rows: [[false]]} ->
                  :ok

                %{rows: [[true]]} ->
                  Repo.query!("SELECT pg_advisory_unlock($1)", [Lease.lock_key(message_id)])
                  flunk("Cleanup released its advisory lock before clearing the fence")
              end

              send(parent, :cleanup_blocked)
          after
            @timeout -> flunk("Missing cleanup wait-graph barrier")
          end

          receive do
            :finish -> :ok
          after
            @timeout -> flunk("Missing row-fence release")
          end
        end)
      end)

    assert_receive {:holder_backend, backend}, @timeout
    Map.put(holder, :backend, backend)
  end

  defp assert_cleanup_blocked!(holder, cleanup_backend) do
    assert holder.backend != cleanup_backend
    send(holder.pid, {:await_cleanup, cleanup_backend})
    assert_receive :cleanup_blocked, @timeout
  end

  defp db_task!(fun) do
    parent = self()
    ref = make_ref()

    pid =
      start_supervised!(%{
        id: ref,
        start:
          {Task, :start_link,
           [
             fn ->
               result =
                 try do
                   Sandbox.unboxed_run(Repo, fun)
                 rescue
                   error -> {:raised, error, __STACKTRACE__}
                 end

               send(parent, {:db_result, ref, result})
             end
           ]},
        restart: :temporary
      })

    %{pid: pid, ref: ref, monitor: Process.monitor(pid)}
  end

  defp finish!(%{pid: pid, ref: ref, monitor: monitor}) do
    assert_receive {:db_result, ^ref, result}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, @timeout
    assert reason in [:normal, :noproc]

    case result do
      {:raised, error, stacktrace} -> reraise error, stacktrace
      result -> result
    end
  end

  @doc false
  def pause_after_commit(_event, _measurements, %{query: query}, _config) do
    if String.downcase(query) == "commit" do
      case Process.delete({__MODULE__, :pause_commit}) do
        parent when is_pid(parent) ->
          send(parent, {:claim_committed, self()})

          receive do
            :continue_claim -> :ok
          after
            @timeout -> flunk("Missing committed-owner termination")
          end

        nil ->
          :ok
      end
    end
  end

  @doc false
  def pause_cleanup_before_lock(_event, _measurements, %{query: query}, {parent, manager}) do
    if String.downcase(query) == "begin" and manager in List.wrap(Process.get(:"$callers")) do
      send(parent, {:cleanup_before_lock, self()})

      receive do
        :continue_cleanup -> :ok
      after
        @timeout -> flunk("Missing old-cleanup continuation")
      end
    end
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp await_blocked!(waiter, blocker, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout

    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [blocker, waiter])

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline, "Expected a real PostgreSQL row wait"
      await_blocked!(waiter, blocker, deadline)
    end

    :ok
  end

  defp await_unleased!(message_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout

    if Map.has_key?(:sys.get_state(Lease).leases, message_id) do
      assert System.monotonic_time(:millisecond) < deadline, "Lease cleanup did not finish"
      await_unleased!(message_id, deadline)
    end
  end

  defp await_new_manager!(previous, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout

    case Process.whereis(Lease) do
      pid when is_pid(pid) and pid != previous ->
        _ = :sys.get_state(pid)
        pid

      _other ->
        assert System.monotonic_time(:millisecond) < deadline, "Lease manager did not restart"
        await_new_manager!(previous, deadline)
    end
  end

  defp acquire_after_manager_restart!(message_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout

    case Lease.acquire(message_id) do
      {:ok, lease} ->
        lease

      {:error, :already_running} ->
        # The old connection process has exited, but PostgreSQL may not yet
        # have observed its closed socket and released the session lock.
        assert System.monotonic_time(:millisecond) < deadline,
               "Old advisory session did not close"

        acquire_after_manager_restart!(message_id, deadline)

      failure ->
        flunk("Successor claim failed: #{inspect(failure)}")
    end
  end

  defp message_fixture!(actor) do
    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(:create_generating_assistant, %{chat_id: chat.id}, actor: actor)
      |> Ash.Changeset.force_change_attribute(:generation_fence_token, Ecto.UUID.generate())
      |> Ash.create!(actor: actor)

    %{chat: chat, message: message}
  end
end
