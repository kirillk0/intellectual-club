defmodule IntellectualClub.Test.GenerationRuntime.Barrier do
  @moduledoc """
  Deterministic `:telemetry` barriers for concurrency tests.

  `attach/3` installs a handler; whenever its matcher returns a key for an event
  executed by another process, that process announces itself to the test as
  `{:barrier, key, pid, metadata, token}` and blocks inside the instrumented code
  until the test calls `release/1` or `crash/1` (or the test process exits).

      handler = Barrier.gate_persistence(message_id, provider_completed: :stop)
      writer = Barrier.await_persistence(:provider_completed, :stop)
      # ... assert the state while the writer is held after its commit ...
      Barrier.release(writer)

  Handlers are detached on test exit; `detach/1` stops gating earlier.
  """

  import ExUnit.Assertions

  @persistence [:intellectual_club, :generation, :persistence]
  @timeout 5_000

  defstruct [:key, :pid, :metadata, :identity, :token]

  @doc """
  Holds every process (other than the test) that executes one of `events` while
  `match.(event, measurements, metadata)` returns a key (not `nil`/`false`).

  `around: fun` wraps the wait (`fun.(wait)`), e.g. to hold an open transaction.
  """
  def attach(events, match, opts \\ []) when is_function(match, 3) do
    handler = {__MODULE__, make_ref()}
    events = if is_atom(hd(events)), do: [events], else: events
    config = %{owner: self(), match: match, around: Keyword.get(opts, :around)}
    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, config)
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  @doc """
  Gates Generation persistence operations of `message_id`; `gates` lists
  `{kind, :start | :stop}` pairs (`:start` before, `:stop` after the operation).
  """
  def gate_persistence(message_id, gates) do
    gates = MapSet.new(gates)

    attach([@persistence ++ [:start], @persistence ++ [:stop]], fn event, _measurements, meta ->
      key = {meta[:kind], List.last(event)}
      meta[:message_id] == message_id and key in gates and key
    end)
  end

  def detach(handler), do: :telemetry.detach(handler)

  @doc "Waits for a process held at `key`."
  def await(key, timeout \\ @timeout) do
    assert_receive {:barrier, ^key, pid, metadata, token}, timeout
    %__MODULE__{key: key, pid: pid, metadata: metadata, token: token}
  end

  @doc """
  Waits for a persistence operation held at `{kind, stage}`; `identity` is its
  metadata without the `:outcome`, equal at both stages of one operation.
  """
  def await_persistence(kind, stage, timeout \\ @timeout) do
    barrier = await({kind, stage}, timeout)
    %{barrier | identity: Map.delete(barrier.metadata, :outcome)}
  end

  def release(%__MODULE__{pid: pid, token: token}), do: send(pid, {token, :continue})

  @doc "Kills the held process (a lost acknowledgment) and waits for its exit."
  def crash(%__MODULE__{pid: pid, token: token}) do
    monitor = Process.monitor(pid)
    send(pid, {token, :crash})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @timeout
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, %{owner: owner} = config) do
    if self() != owner do
      case config.match.(event, measurements, metadata) do
        key when key in [nil, false] -> :ok
        key -> hold(owner, key, metadata, config.around)
      end
    end
  end

  defp hold(owner, key, metadata, nil), do: wait(owner, key, metadata)
  defp hold(owner, key, metadata, around), do: around.(fn -> wait(owner, key, metadata) end)

  defp wait(owner, key, metadata) do
    token = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {:barrier, key, self(), metadata, token})

    try do
      receive do
        {^token, :continue} -> :ok
        {^token, :crash} -> Process.exit(self(), :kill)
        {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end
end
