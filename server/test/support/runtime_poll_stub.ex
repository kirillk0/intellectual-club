defmodule IntellectualClub.Test.RuntimePollStub do
  @moduledoc false
  use GenServer
  alias IntellectualClub.Generation.{RuntimePoll, RuntimeTrace}

  def start_link({message_id, step}), do: GenServer.start_link(__MODULE__, {message_id, step})
  @impl true
  def init({message_id, step}) do
    Registry.register(IntellectualClub.Generation.Registry, {:message, message_id}, %{})
    {:ok, %{step: step, epoch: Ash.UUID.generate(), full_snapshots: 0}}
  end

  @impl true
  def handle_call({:event, event}, _from, state),
    do: {:reply, :ok, %{state | step: RuntimeTrace.apply_event(state.step, event)}}

  def handle_call({:poll, cursor, [protocol: :cursor]}, _from, state) do
    reply = RuntimePoll.poll(state.step, state.epoch, cursor)
    snapshots = state.full_snapshots + if(reply.stream.reset, do: 1, else: 0)

    {:reply, Map.merge(reply, %{status: :generating, phase: :provider}),
     %{state | full_snapshots: snapshots}}
  end

  def handle_call({:poll, _cursor, _opts}, _from, state),
    do:
      {:reply, %{status: :generating, phase: :provider, step: RuntimeTrace.snapshot(state.step)},
       state}
end
