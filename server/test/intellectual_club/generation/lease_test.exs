defmodule IntellectualClub.Generation.LeaseTest do
  use IntellectualClub.DataCase, async: false

  import ExUnit.CaptureLog
  import IntellectualClub.Test.GenerationRuntime

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep, QueuedMessage, QueuedMessages}
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Lease.Capabilities
  alias IntellectualClub.Generation.{Persistence, QueueCoordinator, Worker}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Notifications.WebPushGenerationEvent
  alias IntellectualClub.Test.GenerationRuntime.ScriptedSessionAdapter

  require Ash.Query

  @timeout 10_000

  describe "session lease and local capability" do
    test "a session lease excludes another database session and becomes stale after release" do
      %{message: message} = fixture = generation_fixture!()
      assert {:ok, lease} = Lease.acquire(message.id)
      assert is_binary(lease.fence_token)
      assert {:ok, :written} = Lease.with_fence(lease, fn -> :written end)

      assert {:ok, %{rows: [[false]]}} =
               Repo.query("SELECT pg_try_advisory_lock($1)", [Lease.lock_key(message.id)])

      assert :ok = Lease.release(lease)
      assert {:error, :lease_lost} = Lease.with_fence(lease, fn -> :stale_write end)
      assert message!(fixture).generation_fence_token == nil

      assert {:ok, %{rows: [[true]]}} =
               Repo.query("SELECT pg_try_advisory_lock($1)", [Lease.lock_key(message.id)])

      assert {:ok, %{rows: [[true]]}} =
               Repo.query("SELECT pg_advisory_unlock($1)", [Lease.lock_key(message.id)])
    end

    test "local lease checks do not enter the manager mailbox and match the full capability" do
      %{message: message} = generation_fixture!()
      assert {:ok, lease} = Lease.acquire(message.id)

      assert Capabilities.active?(lease)
      refute Capabilities.active?(%{lease | manager: self()})
      refute Capabilities.active?(%{lease | ref: make_ref()})
      refute Capabilities.active?(%{lease | fence_token: Ecto.UUID.generate()})
      refute Capabilities.active?(%{lease | fence_token: nil})

      with_suspended_manager(lease, fn ->
        assert {:ok, :written_without_rpc} =
                 run_in_task(fn -> Lease.with_fence(lease, fn -> :written_without_rpc end) end)
      end)
    end

    @tag :whitebox
    test "dispatch admission uses only the registered fenced capability without SQL or manager calls" do
      %{message: message} = generation_fixture!()
      assert {:ok, reservation} = Lease.reserve(message.id)
      refute Lease.dispatch_allowed?(reservation)
      assert {:ok, lease} = Lease.fence(reservation)
      parent = self()
      handler_id = {__MODULE__, :dispatch_queries, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:intellectual_club, :repo, :query],
          fn _, _, _, recipient -> send(recipient, {:dispatch_query, self()}) end,
          parent
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      with_suspended_manager(lease, fn ->
        checker =
          run_in_task(fn ->
            assert Lease.dispatch_allowed?(lease)
            refute Lease.dispatch_allowed?(nil)
            refute Lease.dispatch_allowed?(%{})
            refute Lease.dispatch_allowed?(reservation)
            refute Lease.dispatch_allowed?(%{lease | manager: self()})
            refute Lease.dispatch_allowed?(%{lease | ref: make_ref()})
            refute Lease.dispatch_allowed?(%{lease | fence_token: Ecto.UUID.generate()})
            self()
          end)

        refute_received {:dispatch_query, ^checker}
      end)

      refute Lease.dispatch_allowed?(lease)
    end

    test "missing local capability state fails closed without affecting token-only fences" do
      %{message: message} = fixture = generation_fixture!()
      assert {:ok, lease} = Lease.acquire(message.id)

      try do
        :sys.replace_state(lease.manager, fn state ->
          :ets.delete(Capabilities)
          state
        end)

        refute Capabilities.active?(lease)
        refute Lease.dispatch_allowed?(lease)

        assert {:error, :lease_lost} =
                 Lease.with_fence(lease, fn -> flunk("lost capability authorized a write") end)

        assert {:ok, :token_only} =
                 Lease.with_token_fence(message.id, lease.fence_token, fn -> :token_only end)

        assert :ok = Lease.release(lease)
        assert message!(fixture).generation_fence_token == nil
      after
        Lease.release(lease)
        :ok = Supervisor.terminate_child(IntellectualClub.Supervisor, Lease)
        assert {:ok, _manager} = Supervisor.restart_child(IntellectualClub.Supervisor, Lease)
      end
    end

    test "a live local capability never bypasses the durable row-locked token check" do
      %{actor: actor, message: message} = fixture = generation_fixture!()
      assert {:ok, lease} = Lease.acquire(message.id)
      replacement_token = Ecto.UUID.generate()

      message
      |> Ash.Changeset.for_update(
        :set_generation_fence,
        %{generation_fence_token: replacement_token},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      assert {:error, :lease_lost} =
               Lease.with_fence(lease, fn -> flunk("stale durable token authorized a write") end)

      assert :ok = Lease.release(lease)
      assert message!(fixture).generation_fence_token == replacement_token
    end
  end

  describe "fence claims" do
    test "successful fence registration does not abandon its completed claim" do
      %{message: message} = generation_fixture!()
      assert {:ok, reservation} = Lease.reserve(message.id)
      manager = reservation.manager
      trace_receives!(manager)

      try do
        assert {:ok, lease} = Lease.fence(reservation)
        delivery = :erlang.trace_delivered(manager)
        assert_receive {:trace_delivered, ^manager, ^delivery}

        assert_received {:trace, ^manager, :receive,
                         {:"$gen_call", _, {:prepare_fence, ^lease, _}}}

        assert_received {:trace, ^manager, :receive,
                         {:"$gen_call", _, {:register_fence, ^lease, _}}}

        refute_received {:trace, ^manager, :receive, {:"$gen_call", _, {:abandon_fence_claim, _}}}

        entry = :sys.get_state(manager).leases[message.id]
        assert entry.claim_token == nil
        assert entry.fence_token == lease.fence_token
        assert lease.fence_token in entry.cleanup_tokens
      after
        :erlang.trace(manager, false, [:receive])
        Lease.release(reservation)
      end
    end

    test "failed and thrown fence claims release their claim slot for a retry" do
      %{message: message} = fixture = generation_fixture!()
      assert {:ok, reservation} = Lease.reserve(message.id)

      try do
        assert {:error, :invalid_status} =
                 Lease.claim_and_run(reservation, [:error], fn -> flunk("invalid status") end)

        assert :sys.get_state(reservation.manager).leases[message.id].claim_token == nil

        assert catch_throw(
                 Lease.claim_and_run(reservation, [:generating], fn -> throw(:claim_aborted) end)
               ) == :claim_aborted

        entry = :sys.get_state(reservation.manager).leases[message.id]
        assert entry.claim_token == nil
        assert length(entry.cleanup_tokens) == 2
        assert message!(fixture).generation_fence_token == nil
        assert {:ok, lease} = Lease.fence(reservation)
        assert Lease.dispatch_allowed?(lease)
      after
        Lease.release(reservation)
      end
    end

    test "a normal acquire rejects a terminal message without leaving a fence token" do
      %{actor: actor, message: message} = fixture = generation_fixture!()
      set_message_status!(actor, message, :done, finished_at: DateTime.utc_now())

      assert {:error, :invalid_status} = Lease.acquire(message.id)
      assert message!(fixture).generation_fence_token == nil

      assert {:ok, reservation} = Lease.reserve(message.id)
      assert :ok = Lease.release(reservation)
    end

    test "a retry claim is rejected when another generation won the chat turn" do
      %{actor: actor, chat: chat, message: message} = fixture = failed_generation!()
      other = create_generating_message!(actor, chat, %{parent_id: message.id, token_count: 0})
      assert other.status == :generating
      assert {:ok, reservation} = Lease.reserve(message.id)

      assert {:error, :generation_active} =
               Lease.claim_and_run_with_chat(reservation, chat.id, [:error], fn -> :claimed end)

      target = message!(fixture)
      assert target.status == :error
      assert target.generation_fence_token == nil
      assert :ok = Lease.release(reservation)
    end

    test "a retry claim rolls back its fence token when the mutation raises" do
      %{message: message} = fixture = failed_generation!()
      assert {:ok, reservation} = Lease.reserve(message.id)

      assert_raise RuntimeError, "retry mutation failed", fn ->
        Lease.claim_and_run(reservation, [:error], fn -> raise "retry mutation failed" end)
      end

      assert message!(fixture).generation_fence_token == nil
      assert {:error, :lease_not_fenced} = Lease.with_fence(reservation, fn -> :stale_write end)
      entry = :sys.get_state(reservation.manager).leases[message.id]
      assert entry.claim_token == nil
      assert length(entry.cleanup_tokens) == 1

      assert {:ok, {_lease, :retried}} =
               Lease.claim_and_run(reservation, [:error], fn -> :retried end)

      assert :ok = Lease.release(reservation)
      test_pid = self()

      assert {:error, :lease_lost} =
               Lease.claim_and_run(reservation, [:error], fn ->
                 send(test_pid, :stale_retry_mutation)
               end)

      refute_received :stale_retry_mutation
      assert message!(fixture).generation_fence_token == nil
    end

    test "retry lock preparation runs inside the transaction before its row fences" do
      %{chat: chat, message: message} = fixture = failed_generation!()
      assert {:ok, reservation} = Lease.reserve(message.id)
      handler_id = {__MODULE__, :prelock_order, make_ref()}
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:intellectual_club, :repo, :query],
          fn _, _, metadata, caller ->
            if self() == caller and String.contains?(metadata.query, "FOR NO KEY UPDATE") do
              send(caller, {:lease_row_fence, metadata.query})
            end
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      scope = fn callback ->
        assert Repo.in_transaction?()
        refute_received {:lease_row_fence, _query}
        send(test_pid, :retry_locks_prepared)
        callback.(:prepared)
      end

      try do
        assert {:ok, {lease, :replaced}} =
                 Lease.claim_and_run_with_chat(
                   reservation,
                   chat.id,
                   [:error],
                   fn :prepared ->
                     assert_received :retry_locks_prepared
                     assert_received {:lease_row_fence, _query}
                     :replaced
                   end,
                   with_lock_scope: scope
                 )

        assert is_binary(lease.fence_token)
        assert message!(fixture).generation_fence_token == lease.fence_token
        assert :ok = Lease.release(lease)
      after
        Lease.release(reservation)
      end
    end

    test "a lock scope passes its value to the mutation and expires before lease registration" do
      %{chat: chat, message: message} = failed_generation!()
      assert {:ok, reservation} = Lease.reserve(message.id)
      key = {__MODULE__, make_ref()}
      prepared = make_ref()

      scope = fn callback ->
        assert Repo.in_transaction?()
        Process.put(key, prepared)

        try do
          callback.(prepared)
        after
          Process.delete(key)
        end
      end

      try do
        assert {:ok, {lease, :replaced}} =
                 Lease.claim_and_run_with_chat(
                   reservation,
                   chat.id,
                   [:error],
                   fn value ->
                     assert value == prepared
                     assert Process.get(key) == prepared
                     :replaced
                   end,
                   with_lock_scope: scope
                 )

        assert Process.get(key) == nil

        assert {:ok, :continued} =
                 Lease.with_fence(
                   lease,
                   fn value ->
                     assert value == prepared
                     assert Process.get(key) == prepared
                     :continued
                   end,
                   with_lock_scope: scope
                 )

        assert Process.get(key) == nil
        assert :ok = Lease.release(lease)

        assert {:error, :lease_lost} =
                 Lease.with_fence(
                   lease,
                   fn _ -> flunk("stale mutation") end,
                   with_lock_scope: fn _ -> flunk("stale scope") end
                 )
      after
        Lease.release(reservation)
      end
    end

    test "a rejected scoped preparation never enters the retry fence" do
      %{chat: chat, message: message} = fixture = failed_generation!()
      assert {:ok, reservation} = Lease.reserve(message.id)

      try do
        assert {:error, :dependencies_changed} =
                 Lease.claim_and_run_with_chat(
                   reservation,
                   chat.id,
                   [:error],
                   fn _ -> flunk("unexpected mutation") end,
                   with_lock_scope: fn _ -> {:error, :dependencies_changed} end
                 )

        assert message!(fixture).generation_fence_token == nil
      after
        Lease.release(reservation)
      end
    end
  end

  describe "fenced persistence" do
    test "terminal persistence clears the durable fence in the same transaction" do
      %{chat: chat, message: message, step_id: step_id} = fixture = generation_fixture!()
      assert {:ok, lease} = Lease.acquire(message.id)

      assert {:ok, :ok} =
               Lease.with_chat_fence(
                 lease,
                 chat.id,
                 fn -> Persistence.persist_completed_from_step!(message.id, step_id) end,
                 allowed_statuses: [:generating],
                 required_role: :assistant
               )

      terminal = message!(fixture)
      assert terminal.status == :done
      assert terminal.generation_fence_token == nil
      assert :ok = Lease.release(lease)
    end

    test "fenced persistence dispatches Ash notifications after the transaction commits" do
      %{message: message, step_id: step_id, context: context} = generation_fixture!()

      log =
        capture_log(fn ->
          assert {:ok, lease} = Lease.acquire(message.id)

          assert {:ok, %{step_sequence: 2}} =
                   Lease.with_fence(lease, fn ->
                     Persistence.persist_retry_error_and_start_next_step!(
                       message.id,
                       step_id,
                       context.request_payload,
                       "Temporary provider error",
                       attempt: 1,
                       retry_delay_ms: 1_000,
                       retryable: true,
                       lease: lease
                     )
                   end)

          assert :ok = Lease.release(lease)
        end)

      refute log =~ "notifications in action IntellectualClub.Chat.ChatMessage"
    end

    test "durable cancellation still broadcasts canceled after clearing the fence token" do
      %{chat: chat, message: message} = fixture = generation_fixture!()
      %{worker: worker} = start_managed_worker!(fixture)
      worker_ref = Process.monitor(worker)
      :ok = Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

      assert :ok = GenerationSupervisor.cancel_generation(message.id)
      message_id = message.id
      assert_receive {:canceled, ^message_id}, 1_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000

      canceled = message!(fixture)
      assert canceled.status == :canceled
      assert canceled.error_detail == nil
      assert canceled.generation_fence_token == nil
    end
  end

  describe "heartbeat and connection loss" do
    test "lease connection loss kills its worker and restart recovery handles the orphan" do
      put_app_env(:recover_orphaned_generations_on_startup, true)

      %{actor: actor, message: message} =
        fixture = generation_fixture!(context: [test_session: :term])

      %{worker: worker, token: persisted_token} =
        start_managed_worker!(fixture, ScriptedSessionAdapter)

      message_id = message.id
      assert_receive {:provider_session_started, ^message_id, session}
      manager = Process.whereis(Lease)
      manager_ref = Process.monitor(manager)
      worker_ref = Process.monitor(worker)

      Process.exit(Lease.connection_pid(), :kill)

      assert_receive {:DOWN, ^manager_ref, :process, ^manager, _reason}, 2_000
      assert_receive {:provider_session_stopped, ^message_id, ^session}, 2_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000
      wait_until(fn -> Process.whereis(Lease) not in [nil, manager] end, 2_000)

      # Startup recovery restarts the orphan under a new fence (or settles it).
      recovered =
        wait_until(
          fn ->
            current = message!(fixture)

            (current.status != :generating or
               match?({:ok, _state}, GenerationSupervisor.get_generation_state(message_id))) and
              current
          end,
          8_000
        )

      assert message!(fixture).generation_fence_token != persisted_token
      assert recovered.status in [:generating, :done, :error, :canceled]

      cleaned =
        wait_until(
          fn ->
            current = Ash.get!(ChatMessage, message_id, actor: actor)

            case {current.status, GenerationSupervisor.get_generation_state(message_id)} do
              {status, :not_found} when status != :generating ->
                current

              {:generating, {:ok, _state}} ->
                _ = GenerationSupervisor.cancel_generation(message_id)
                nil

              _other ->
                nil
            end
          end,
          timeout: 4_000,
          interval: 20
        )

      assert cleaned.status in [:done, :error, :canceled]
      assert message!(fixture).generation_fence_token == nil
      assert GenerationSupervisor.get_generation_state(message_id) == :not_found
    end

    test "heartbeat stops a partitioned stale worker and releases its advisory lock" do
      %{message: message} = fixture = generation_fixture!()
      %{worker: worker, token: stale_token} = start_managed_worker!(fixture)
      worker_ref = Process.monitor(worker)
      assert :canceled = Persistence.cancel_generating_message!(message.id, error_detail: nil)
      assert :ok = Lease.trigger_validation()
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000

      canceled = message!(fixture)
      assert canceled.status == :canceled
      assert canceled.generation_fence_token == nil
      reservation = reserve_eventually!(message.id)

      assert {:ok, {retry_lease, :retry_claimed}} =
               Lease.claim_and_run(reservation, [:canceled], fn -> :retry_claimed end)

      assert retry_lease.fence_token != stale_token

      assert {:error, :lease_lost} =
               Lease.with_token_fence(message.id, stale_token, fn -> :stale_write end)

      assert :ok = Lease.release(retry_lease)
    end

    test "heartbeat force fallback kills a suspended worker and its owned provider session" do
      %{message: message} = fixture = generation_fixture!()
      %{worker: worker, lease: lease} = start_managed_worker!(fixture, ScriptedSessionAdapter)
      message_id = message.id
      assert_receive {:provider_session_started, ^message_id, session}
      assert worker in elem(Process.info(session, :links), 1)
      worker_ref = Process.monitor(worker)
      session_ref = Process.monitor(session)

      assert :ok = :sys.suspend(worker)
      assert :canceled = Persistence.cancel_generating_message!(message.id, error_detail: nil)
      assert :ok = Lease.trigger_validation()

      # Validation first asks the owner to stop; the suspended owner cannot react.
      wait_until(fn ->
        {:"$gen_cast", :generation_fence_lost} in elem(Process.info(worker, :messages), 1)
      end)

      # Deliver the force-stop fallback the manager scheduled after its grace period.
      send(lease.manager, {:force_stop_generation_owner, message.id, lease.ref, worker})
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 2_000
      assert_receive {:DOWN, ^session_ref, :process, ^session, :killed}, 1_000
      assert :ok = Lease.release(reserve_eventually!(message.id))
    end

    test "periodic orphan recovery remains scheduled after the startup retry window" do
      manager = Process.whereis(Lease)
      put_app_env(:recover_orphaned_generations_on_startup, true)
      put_app_env(:generation_orphan_recovery_interval_ms, 25)
      on_exit(fn -> if Process.alive?(manager), do: :sys.resume(manager) end)

      send(manager, :recover_orphaned_generations_periodic)
      assert is_pid(Lease.connection_pid())
      assert :ok = :sys.suspend(manager)

      wait_until(fn ->
        :recover_orphaned_generations_periodic in elem(Process.info(manager, :messages), 1)
      end)

      put_app_env(:recover_orphaned_generations_on_startup, false)
      assert :ok = :sys.resume(manager)
    end
  end

  describe "lock interplay across database sessions" do
    # Whitebox: asserts PostgreSQL lock order and wait graphs, not behavior.
    # Every workload task checks out its own unboxed connection; data is committed.
    @describetag :whitebox
    @describetag sandbox: false

    setup do
      %{user: actor} = user_fixture(%{username: "lease-locks-#{Ecto.UUID.generate()}"})
      source = committed_message_fixture!(actor)
      unrelated = committed_message_fixture!(actor)
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

    test "coordinator chat fence does not form an FK cycle with a message-fenced writer",
         fixture do
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
  end

  defp failed_generation! do
    fixture = generation_fixture!()
    set_message_status!(fixture.actor, fixture.message, :error, finished_at: DateTime.utc_now())
    fixture
  end

  # Starts a Worker under the Generation supervisor (as production does) and
  # waits for its provider request; returns the Worker, its lease and fence.
  defp start_managed_worker!(fixture, adapter \\ nil) do
    fixture = if adapter, do: with_context(fixture, adapter_module: adapter), else: fixture
    assert {:ok, lease} = Lease.acquire(fixture.message.id)

    spec = %{
      id: {Worker, fixture.message.id},
      start:
        {Worker, :start_link, [%{context: fixture.context, lease: lease, lease_owner: self()}]},
      restart: :temporary
    }

    assert {:ok, worker} = DynamicSupervisor.start_child(GenerationSupervisor, spec)
    await_provider!(fixture)
    token = message!(fixture).generation_fence_token
    assert is_binary(token)
    %{worker: worker, lease: lease, token: token}
  end

  defp with_suspended_manager(lease, fun) do
    assert :ok = :sys.suspend(lease.manager)

    try do
      fun.()
    after
      :sys.resume(lease.manager)
      Lease.release(lease)
    end
  end

  # Runs `fun` in a separate supervised process and returns its result.
  defp run_in_task(fun) do
    parent = self()
    ref = make_ref()

    pid =
      start_supervised!(%{
        id: ref,
        start: {Task, :start_link, [fn -> send(parent, {ref, fun.()}) end]},
        restart: :temporary
      })

    monitor = Process.monitor(pid)
    assert_receive {^ref, result}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 1_000
    assert reason in [:normal, :noproc]
    result
  end

  defp reserve_eventually!(message_id) do
    wait_until(
      fn ->
        case Lease.reserve(message_id) do
          {:ok, reservation} -> reservation
          {:error, :already_running} -> nil
          {:error, reason} -> flunk("Could not reserve generation lease: #{inspect(reason)}")
        end
      end,
      timeout: 2_000,
      interval: 20
    )
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

  defp committed_message_fixture!(actor) do
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
