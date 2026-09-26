defmodule IntellectualClub.Generation.PersistenceOperation do
  @moduledoc false

  alias IntellectualClub.Generation.Lease

  @supervisor IntellectualClub.Generation.PersistenceTasks
  @event [:intellectual_club, :generation, :persistence]

  @enforce_keys [:identity, :task]
  defstruct [:identity, :task]

  def start(kind, message_id, step_id, lease, fun, opts \\ [])
      when is_atom(kind) and is_integer(message_id) and is_function(fun, 0) do
    owner = self()

    identity =
      Map.merge(scope(message_id, step_id, lease), %{
        id: make_ref(),
        kind: kind,
        owner: owner
      })

    task =
      Task.Supervisor.async_nolink(Keyword.get(opts, :supervisor, @supervisor), fn ->
        watch_owner(owner)
        started = System.monotonic_time()
        :telemetry.execute(@event ++ [:start], %{system_time: System.system_time()}, identity)
        result = fun.()

        :telemetry.execute(
          @event ++ [:stop],
          %{duration: System.monotonic_time() - started},
          Map.put(identity, :outcome, outcome(result))
        )

        {:persistence_result, identity, result}
      end)

    %__MODULE__{identity: identity, task: task}
  end

  def matches?(
        %__MODULE__{task: %Task{ref: ref}, identity: identity},
        ref,
        identity,
        message_id,
        step_id,
        lease
      ) do
    Map.take(identity, [:message_id, :step_id, :lease_ref, :fence_token, :lease_manager]) ==
      scope(message_id, step_id, lease)
  end

  def matches?(_operation, _ref, _identity, _message_id, _step_id, _lease), do: false

  def acknowledge(%__MODULE__{task: %Task{ref: ref}}) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  def shutdown(nil), do: :ok

  def shutdown(%__MODULE__{task: task}) do
    # Join the writer before releasing the lease. Fence cleanup subsequently
    # serializes with any DB commit/rollback still finishing on its connection.
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp scope(message_id, step_id, %Lease{} = lease) do
    %{
      message_id: message_id,
      step_id: step_id,
      lease_ref: lease.ref,
      fence_token: lease.fence_token,
      lease_manager: lease.manager
    }
  end

  defp scope(message_id, step_id, nil) do
    %{
      message_id: message_id,
      step_id: step_id,
      lease_ref: nil,
      fence_token: nil,
      lease_manager: nil
    }
  end

  defp outcome({:error, _reason}), do: :error
  defp outcome(_result), do: :ok

  defp watch_owner(owner) do
    writer = self()
    ready = make_ref()

    # The writer is deliberately unlinked from the Worker. A separate small
    # guardian can receive owner death while the writer is blocked in the DB;
    # terminate/2 alone cannot protect a Worker killed with :kill.
    spawn_link(fn ->
      owner_ref = Process.monitor(owner)
      writer_ref = Process.monitor(writer)
      send(writer, {ready, :watching})

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(writer, :kill)
        {:DOWN, ^writer_ref, :process, ^writer, _reason} -> :ok
      end
    end)

    receive do
      {^ready, :watching} -> :ok
    end
  end
end
