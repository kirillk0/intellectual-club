defmodule IntellectualClub.SandboxCleanup do
  @moduledoc false

  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Recovery
  alias IntellectualClub.Generation.Worker

  @drain_timeout_ms 30_000
  @background_supervisor IntellectualClub.BackgroundTasks.Supervisor
  @execution_supervisor IntellectualClub.BackgroundTasks.ExecutionSupervisor
  @generation_supervisor IntellectualClub.Generation.Supervisor
  @persistence_supervisor IntellectualClub.Generation.PersistenceTasks
  @cleanup_supervisor IntellectualClub.Generation.LeaseCleanupSupervisor
  @notifications_supervisor IntellectualClub.Notifications.Dispatcher
  @supervisors [
    @background_supervisor,
    @execution_supervisor,
    @generation_supervisor,
    @persistence_supervisor,
    @cleanup_supervisor,
    @notifications_supervisor
  ]

  # Call only for a shared sandbox, while its separate SQL owner is still alive.
  def stop_background_tasks! do
    deadline = System.monotonic_time(:millisecond) + @drain_timeout_ms

    # Keep the original PIDs: an empty replacement manager is not an
    # acknowledgement that the old manager successfully cleared its fences.
    lease = server_pid!(Lease)
    recovery = server_pid!(Recovery)
    drain(lease, recovery, deadline)
  end

  defp drain(lease, recovery, deadline) do
    remaining!(deadline, :background_tasks)
    stop_producers(deadline)

    # terminate_child would make Worker.terminate/2 kill its SQL writer. Even
    # with a live sandbox owner, killing a checked-out borrower destroys the
    # shared ownership proxy. Cancellation joins persistence before releasing
    # the lease; fixtures must release their test barriers before this drain.
    cancel_generation_workers(deadline)
    _ = :sys.get_state(IntellectualClub.Generation.QueueDispatcher, remaining!(deadline, :queue))
    await_recovery(recovery, deadline)

    # Recovery can start new workers. Stop its descendants with the sandbox
    # still open, rather than treating recovery's DOWN as global quiescence.
    stop_producers(deadline)
    cancel_generation_workers(deadline)

    # Join orphan-guardian exits as well as the workers' persistence tasks.
    # Never interrupt a SQL borrower while its shared connection is needed.
    await_tasks(@persistence_supervisor, deadline, [:normal, :noproc, :shutdown, :killed])

    # Cleanup must compare-and-clear the durable fence, then let Lease handle
    # the result and unlock. Killing these tasks would crash the lease manager.
    await_tasks(@cleanup_supervisor, deadline, [:normal, :noproc])

    await_tasks(@notifications_supervisor, deadline, [:normal, :noproc])
    recovery_state = :sys.get_state(recovery, remaining!(deadline, :recovery_acknowledgement))
    children = Map.new(@supervisors, &{&1, child_pids(&1)})
    lease_state = :sys.get_state(lease, remaining!(deadline, :lease_acknowledgement))

    if map_size(lease_state.leases) == 0 and map_size(lease_state.cleanups) == 0 and
         is_nil(recovery_state.task_pid) and not recovery_state.pending? and
         Enum.all?(children, fn {_supervisor, pids} -> pids == [] end) do
      :ok
    else
      # DOWN can reach us before the owner's EXIT or the task result reaches
      # its manager. Re-read via a mailbox barrier, and reap any late workers.
      remaining!(deadline, %{
        leases: lease_state.leases,
        cleanups: lease_state.cleanups,
        recovery_task: recovery_state.task_pid,
        recovery_pending?: recovery_state.pending?,
        children: children
      })

      drain(lease, recovery, deadline)
    end
  end

  defp stop_producers(deadline) do
    stop_background_workers(deadline)

    # Execution and maintenance tasks can own SQL transactions too. Let them
    # return the connection, then stop any workers they started before exiting.
    await_tasks(@execution_supervisor, deadline, [:normal, :noproc])
    stop_background_workers(deadline)
  end

  defp cancel_generation_workers(deadline) do
    workers = Enum.map(child_pids(@generation_supervisor), &{&1, Process.monitor(&1)})
    Enum.each(workers, fn {pid, _ref} -> Worker.cancel(pid) end)

    Enum.each(workers, fn {pid, ref} ->
      await_down(pid, @generation_supervisor, deadline, [:normal, :noproc], ref)
    end)
  end

  defp stop_background_workers(deadline) do
    Enum.each(child_pids(@background_supervisor), fn pid ->
      ref = Process.monitor(pid)

      # Unlike an exit signal, a system stop is handled after the current
      # GenServer callback returns its SQL connection.
      try do
        GenServer.stop(pid, :normal, remaining!(deadline, {@background_supervisor, pid}))
      catch
        :exit, {reason, {GenServer, :stop, _args}} when reason in [:normal, :noproc] -> :ok
      end

      await_down(pid, @background_supervisor, deadline, [:normal, :noproc], ref)
    end)
  end

  defp await_recovery(recovery, deadline) do
    case :sys.get_state(recovery, remaining!(deadline, :recovery)) do
      %Recovery{task_pid: nil, pending?: false} ->
        :ok

      %Recovery{task_pid: pid} when is_pid(pid) ->
        # Recovery uses Task.start_link/1, not a Task.Supervisor. Its pending
        # pass can only start after it consumes this task's EXIT message.
        await_down(pid, Recovery, deadline, [:normal, :noproc])
        await_recovery(recovery, deadline)

      state ->
        ExUnit.Assertions.flunk(
          "Unexpected recovery state during sandbox cleanup: #{inspect(state)}"
        )
    end
  end

  defp await_tasks(supervisor, deadline, expected_reasons) do
    remaining!(deadline, supervisor)

    case child_pids(supervisor) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, &await_down(&1, supervisor, deadline, expected_reasons))
        await_tasks(supervisor, deadline, expected_reasons)
    end
  end

  defp await_down(pid, source, deadline, expected_reasons) do
    await_down(pid, source, deadline, expected_reasons, Process.monitor(pid))
  end

  defp await_down(pid, source, deadline, expected_reasons, ref) do
    timeout = remaining!(deadline, {source, pid})

    try do
      receive do
        {:DOWN, ^ref, :process, ^pid, reason} ->
          unless reason in expected_reasons do
            ExUnit.Assertions.flunk(
              "Sandbox cleanup observed #{inspect(source)} task #{inspect(pid)} " <>
                "exit with #{inspect(reason)}"
            )
          end
      after
        timeout ->
          ExUnit.Assertions.flunk(
            "Sandbox cleanup timed out waiting for #{inspect(source)} task #{inspect(pid)}: " <>
              inspect(Process.info(pid, [:current_function, :current_stacktrace]))
          )
      end
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp child_pids(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} when is_pid(pid) -> pid end)
  end

  defp server_pid!(name) do
    Process.whereis(name) ||
      ExUnit.Assertions.flunk("Missing #{inspect(name)} during shared sandbox cleanup")
  end

  defp remaining!(deadline, waiting_for) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        remaining

      _ ->
        ExUnit.Assertions.flunk("Sandbox cleanup did not quiesce: #{inspect(waiting_for)}")
    end
  end
end
