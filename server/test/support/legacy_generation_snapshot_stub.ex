defmodule IntellectualClub.Generation.LegacyGenerationSnapshotStub do
  @moduledoc false

  use GenServer, restart: :temporary

  alias IntellectualClub.Generation.RuntimeSnapshots

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def handle_call({:publish_snapshot, message_id, snapshot}, _from, test_pid) do
    {:ok, identity} = RuntimeSnapshots.register(message_id)
    :ok = RuntimeSnapshots.publish(message_id, identity, snapshot)
    {:reply, :ok, test_pid}
  end

  def handle_call(:cancel_and_wait, _from, test_pid) do
    send(test_pid, :global_worker_canceled)
    {:stop, :normal, {:error, :not_persisted}, test_pid}
  end

  @impl true
  def handle_cast(:cancel, test_pid) do
    send(test_pid, :global_worker_canceled)
    {:stop, :normal, test_pid}
  end
end
