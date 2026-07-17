defmodule IntellectualClub.Generation.LeaseTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.Worker

  require Ash.Query

  defmodule BlockingAdapter do
    @moduledoc false

    def stream_generate(%{context: context}, _emit) do
      message_id = context.message_id

      message =
        ChatMessage
        |> Ash.Query.filter(id == ^message_id)
        |> Ash.Query.select([:id, :generation_fence_token])
        |> Ash.read_one!(authorize?: false)

      send(
        context.test_pid,
        {:leased_adapter_started, context.message_id, message.generation_fence_token}
      )

      Process.sleep(:infinity)
    end
  end

  defmodule SessionBlockingAdapter do
    @moduledoc false

    def start_session(context) do
      send(context.test_pid, {:provider_session_started, context.message_id})
      {:ok, {context.test_pid, context.message_id}}
    end

    def stop_session({test_pid, message_id}) do
      send(test_pid, {:provider_session_stopped, message_id})
      :ok
    end

    def stream_generate(%{context: context}, _emit) do
      send(context.test_pid, {:leased_adapter_started, context.message_id, :session_adapter})
      Process.sleep(:infinity)
    end
  end

  defmodule PidSessionBlockingAdapter do
    @moduledoc false

    def start_session(context) do
      session = spawn(fn -> session_loop() end)
      send(context.test_pid, {:pid_provider_session_started, context.message_id, session})
      {:ok, session}
    end

    def stop_session(session) when is_pid(session) do
      send(session, :stop)
      :ok
    end

    def stream_generate(%{context: context}, _emit) do
      send(context.test_pid, {:leased_adapter_started, context.message_id, :pid_session_adapter})
      Process.sleep(:infinity)
    end

    defp session_loop do
      receive do
        :stop -> :ok
      end
    end
  end

  test "session lease excludes another database session and becomes stale after release" do
    %{message: message} = generating_message_fixture!()

    assert {:ok, lease} = Lease.acquire(message.id)
    assert is_binary(lease.fence_token)
    assert {:ok, :written} = Lease.with_fence(lease, fn -> :written end)

    assert {:ok, %{rows: [[false]]}} =
             Repo.query("SELECT pg_try_advisory_lock($1)", [Lease.lock_key(message.id)])

    assert :ok = Lease.release(lease)
    assert {:error, :lease_lost} = Lease.with_fence(lease, fn -> :stale_write end)
    assert reloaded_message!(message.id).generation_fence_token == nil

    assert {:ok, %{rows: [[true]]}} =
             Repo.query("SELECT pg_try_advisory_lock($1)", [Lease.lock_key(message.id)])

    assert {:ok, %{rows: [[true]]}} =
             Repo.query("SELECT pg_advisory_unlock($1)", [Lease.lock_key(message.id)])
  end

  test "normal acquire rejects a terminal message without leaving a fence token" do
    %{actor: actor, message: message} = generating_message_fixture!()
    set_message_status!(message, actor, :done)

    assert {:error, :invalid_status} = Lease.acquire(message.id)
    assert reloaded_message!(message.id).generation_fence_token == nil

    assert {:ok, reservation} = Lease.reserve(message.id)
    assert :ok = Lease.release(reservation)
  end

  test "retry claim rolls back its fence token when the mutation raises" do
    %{actor: actor, message: message} = generating_message_fixture!()
    set_message_status!(message, actor, :error)

    assert {:ok, reservation} = Lease.reserve(message.id)

    assert_raise RuntimeError, "retry mutation failed", fn ->
      Lease.claim_and_run(reservation, [:error], fn ->
        raise "retry mutation failed"
      end)
    end

    assert reloaded_message!(message.id).generation_fence_token == nil
    assert {:error, :lease_not_fenced} = Lease.with_fence(reservation, fn -> :stale_write end)
    assert :ok = Lease.release(reservation)

    test_pid = self()

    assert {:error, :lease_lost} =
             Lease.claim_and_run(reservation, [:error], fn ->
               send(test_pid, :stale_retry_mutation)
             end)

    refute_receive :stale_retry_mutation
    assert reloaded_message!(message.id).generation_fence_token == nil
  end

  test "lease connection loss kills its worker and restart recovery handles the orphan" do
    previous_recovery =
      Application.get_env(:intellectual_club, :recover_orphaned_generations_on_startup)

    Application.put_env(:intellectual_club, :recover_orphaned_generations_on_startup, true)

    on_exit(fn ->
      restore_env(:recover_orphaned_generations_on_startup, previous_recovery)
    end)

    %{actor: actor, chat: chat, message: message, step_id: step_id, raw_request: raw_request} =
      generating_message_fixture!()

    assert {:ok, lease} = Lease.acquire(message.id)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: SessionBlockingAdapter,
      request_payload: raw_request,
      timeout_ms: 1_000,
      chunk_delay_ms: 0,
      test_pid: self()
    }

    spec = %{
      id: {Worker, message.id},
      start: {Worker, :start_link, [%{context: context, lease: lease, lease_owner: self()}]},
      restart: :temporary
    }

    assert {:ok, worker} = DynamicSupervisor.start_child(GenerationSupervisor, spec)
    assert_receive {:provider_session_started, message_id}, 1_000
    assert message_id == message.id
    assert_receive {:leased_adapter_started, message_id, token}, 1_000
    assert message_id == message.id
    assert token == :session_adapter

    persisted_token = reloaded_message!(message.id).generation_fence_token
    assert is_binary(persisted_token)

    manager = Process.whereis(Lease)
    connection = Lease.connection_pid()
    manager_ref = Process.monitor(manager)
    worker_ref = Process.monitor(worker)

    Process.exit(connection, :kill)

    assert_receive {:DOWN, ^manager_ref, :process, ^manager, _reason}, 2_000
    assert_receive {:provider_session_stopped, message_id}, 2_000
    assert message_id == message.id
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    new_manager = wait_for_new_manager!(manager, 2_000)
    assert is_pid(new_manager)

    assert {:recovered, recovered} = wait_for_recovery!(message.id, actor, 8_000)
    assert reloaded_message!(message.id).generation_fence_token != persisted_token
    assert recovered.status in [:generating, :done, :error, :canceled]

    cleaned = finish_recovered_generation!(message.id, actor, 4_000)
    assert cleaned.status in [:done, :error, :canceled]
    assert reloaded_message!(message.id).generation_fence_token == nil
    assert GenerationSupervisor.get_generation_state(message.id) == :not_found
  end

  test "heartbeat stops a partitioned stale worker and releases its advisory lock" do
    fixture = generating_message_fixture!()
    %{message: message, actor: actor} = fixture
    %{worker: worker, token: stale_token} = start_managed_worker!(fixture)
    worker_ref = Process.monitor(worker)

    assert :canceled =
             Persistence.cancel_generating_message!(message.id,
               error_detail: nil
             )

    assert :ok = Lease.trigger_validation()
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000

    canceled = Ash.get!(ChatMessage, message.id, actor: actor)
    assert canceled.status == :canceled
    assert canceled.generation_fence_token == nil

    reservation = reserve_eventually!(message.id, 2_000)

    assert {:ok, {retry_lease, :retry_claimed}} =
             Lease.claim_and_run(reservation, [:canceled], fn -> :retry_claimed end)

    assert retry_lease.fence_token != stale_token

    assert {:error, :lease_lost} =
             Lease.with_token_fence(message.id, stale_token, fn -> :stale_write end)

    assert :ok = Lease.release(retry_lease)
  end

  test "heartbeat force fallback kills a suspended worker and its owned provider session" do
    %{actor: actor, chat: chat, message: message, step_id: step_id, raw_request: raw_request} =
      generating_message_fixture!()

    assert {:ok, lease} = Lease.acquire(message.id)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: PidSessionBlockingAdapter,
      request_payload: raw_request,
      timeout_ms: 1_000,
      chunk_delay_ms: 0,
      test_pid: self()
    }

    spec = %{
      id: {Worker, message.id},
      start: {Worker, :start_link, [%{context: context, lease: lease, lease_owner: self()}]},
      restart: :temporary
    }

    assert {:ok, worker} = DynamicSupervisor.start_child(GenerationSupervisor, spec)

    assert_receive {:pid_provider_session_started, message_id, session}, 1_000
    assert message_id == message.id
    assert_receive {:leased_adapter_started, message_id, :pid_session_adapter}, 1_000
    assert message_id == message.id
    assert worker in elem(Process.info(session, :links), 1)

    worker_ref = Process.monitor(worker)
    session_ref = Process.monitor(session)

    assert :ok = :sys.suspend(worker)

    assert :canceled =
             Persistence.cancel_generating_message!(message.id,
               error_detail: nil
             )

    assert :ok = Lease.trigger_validation()
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 3_000
    assert_receive {:DOWN, ^session_ref, :process, ^session, :killed}, 1_000

    reservation = reserve_eventually!(message.id, 2_000)
    assert :ok = Lease.release(reservation)
  end

  test "durable cancellation still broadcasts canceled after clearing the fence token" do
    fixture = generating_message_fixture!()
    %{chat: chat, message: message, actor: actor} = fixture
    %{worker: worker} = start_managed_worker!(fixture)
    worker_ref = Process.monitor(worker)

    :ok = Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    assert :ok = GenerationSupervisor.cancel_generation(message.id)
    assert_receive {:canceled, message_id}, 1_000
    assert message_id == message.id
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000

    canceled = Ash.get!(ChatMessage, message.id, actor: actor)
    assert canceled.status == :canceled
    assert canceled.error_detail == nil
    assert canceled.generation_fence_token == nil
  end

  test "periodic orphan recovery remains scheduled after the startup retry window" do
    manager = Process.whereis(Lease)

    previous_recovery =
      Application.get_env(:intellectual_club, :recover_orphaned_generations_on_startup)

    previous_interval =
      Application.get_env(:intellectual_club, :generation_orphan_recovery_interval_ms)

    Application.put_env(:intellectual_club, :recover_orphaned_generations_on_startup, true)
    Application.put_env(:intellectual_club, :generation_orphan_recovery_interval_ms, 25)

    on_exit(fn ->
      if Process.alive?(manager), do: :sys.resume(manager)
      restore_env(:recover_orphaned_generations_on_startup, previous_recovery)
      restore_env(:generation_orphan_recovery_interval_ms, previous_interval)
    end)

    send(manager, :recover_orphaned_generations_periodic)
    assert is_pid(Lease.connection_pid())
    assert :ok = :sys.suspend(manager)

    Process.sleep(75)

    assert :recover_orphaned_generations_periodic in elem(Process.info(manager, :messages), 1)

    Application.put_env(:intellectual_club, :recover_orphaned_generations_on_startup, false)
    assert :ok = :sys.resume(manager)
  end

  defp generating_message_fixture! do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Lease test", actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "demo-model",
      "messages" => [%{"role" => "user", "content" => "Lease test"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(message.id, 1, raw_request, [])

    %{
      actor: actor,
      chat: chat,
      message: message,
      step_id: step_id,
      raw_request: raw_request
    }
  end

  defp start_managed_worker!(fixture) do
    %{actor: actor, chat: chat, message: message, step_id: step_id, raw_request: raw_request} =
      fixture

    assert {:ok, lease} = Lease.acquire(message.id)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: BlockingAdapter,
      request_payload: raw_request,
      timeout_ms: 1_000,
      chunk_delay_ms: 0,
      test_pid: self()
    }

    spec = %{
      id: {Worker, message.id},
      start: {Worker, :start_link, [%{context: context, lease: lease, lease_owner: self()}]},
      restart: :temporary
    }

    assert {:ok, worker} = DynamicSupervisor.start_child(GenerationSupervisor, spec)
    assert_receive {:leased_adapter_started, message_id, token}, 1_000
    assert message_id == message.id
    assert is_binary(token)

    %{worker: worker, token: token}
  end

  defp reserve_eventually!(message_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_reserve_eventually!(message_id, deadline)
  end

  defp do_reserve_eventually!(message_id, deadline) do
    case Lease.reserve(message_id) do
      {:ok, reservation} ->
        reservation

      {:error, :already_running} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          do_reserve_eventually!(message_id, deadline)
        else
          flunk("Generation lease for message #{message_id} was not released")
        end

      {:error, reason} ->
        flunk("Could not reserve generation lease: #{inspect(reason)}")
    end
  end

  defp set_message_status!(message, actor, status) do
    message
    |> Ash.Changeset.for_update(
      :set_generation_state,
      %{status: status, finished_at: DateTime.utc_now()},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp reloaded_message!(message_id) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id)
    |> Ash.Query.select([:id, :status, :generation_fence_token])
    |> Ash.read_one!(authorize?: false)
  end

  defp wait_for_new_manager!(old_manager, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_new_manager!(old_manager, deadline)
  end

  defp do_wait_for_new_manager!(old_manager, deadline) do
    case Process.whereis(Lease) do
      pid when is_pid(pid) and pid != old_manager ->
        pid

      _other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          do_wait_for_new_manager!(old_manager, deadline)
        else
          flunk("Lease manager did not restart")
        end
    end
  end

  defp wait_for_recovery!(message_id, actor, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_recovery!(message_id, actor, deadline)
  end

  defp do_wait_for_recovery!(message_id, actor, deadline) do
    message = Ash.get!(ChatMessage, message_id, actor: actor)

    cond do
      message.status in [:done, :error, :canceled] ->
        {:recovered, message}

      message.status == :generating and
          match?({:ok, _state}, GenerationSupervisor.get_generation_state(message_id)) ->
        {:recovered, message}

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(25)
        do_wait_for_recovery!(message_id, actor, deadline)

      true ->
        flunk("Message #{message_id} was not recovered after lease manager restart")
    end
  end

  defp finish_recovered_generation!(message_id, actor, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_finish_recovered_generation!(message_id, actor, deadline)
  end

  defp do_finish_recovered_generation!(message_id, actor, deadline) do
    message = Ash.get!(ChatMessage, message_id, actor: actor)

    case {message.status, GenerationSupervisor.get_generation_state(message_id)} do
      {status, :not_found} when status in [:done, :error, :canceled] ->
        message

      {:generating, {:ok, _state}} ->
        _ = GenerationSupervisor.cancel_generation(message_id)
        Process.sleep(20)
        do_finish_recovered_generation!(message_id, actor, deadline)

      _other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          do_finish_recovered_generation!(message_id, actor, deadline)
        else
          flunk("Recovered generation #{message_id} did not settle")
        end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)
end
