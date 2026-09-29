defmodule IntellectualClub.Generation.LegacyGenerationSnapshotStub do
  @moduledoc false

  use GenServer, restart: :temporary

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

  @impl true
  def init(test_pid),
    do:
      {:ok,
       %{test_pid: test_pid, snapshot: %{status: :generating, phase: :initializing, step: nil}}}

  @impl true
  def handle_call({:publish_snapshot, message_id, snapshot}, _from, state) do
    Registry.register(IntellectualClub.Generation.Registry, {:message, message_id}, %{})
    {:reply, :ok, %{state | snapshot: snapshot}}
  end

  def handle_call({:poll, _cursor, _opts}, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:cancel_and_wait, _from, state) do
    send(state.test_pid, :global_worker_canceled)
    {:stop, :normal, {:error, :not_persisted}, state}
  end

  @impl true
  def handle_cast(:cancel, state) do
    send(state.test_pid, :global_worker_canceled)
    {:stop, :normal, state}
  end
end
