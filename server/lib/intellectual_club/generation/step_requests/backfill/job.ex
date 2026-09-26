defmodule IntellectualClub.Generation.StepRequests.Backfill.Job do
  @moduledoc """
  One explicitly requested batch under the existing background DynamicSupervisor.

  Cancellation is cooperative between atomic message transactions. Completed
  progress is retained for one minute, then this temporary child exits normally.
  No request bodies are retained in the process state or sent to the caller.
  """

  use GenServer, restart: :temporary

  alias IntellectualClub.Generation.StepRequests.{Backfill, Reader}

  @retention_ms 60_000

  def start(opts) do
    opts = Backfill.options!(opts)
    DynamicSupervisor.start_child(IntellectualClub.BackgroundTasks.Supervisor, {__MODULE__, opts})
  rescue
    error -> {:error, error}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def status(pid, opts), do: call(pid, :status, opts)
  def cancel(pid, opts), do: call(pid, :cancel, opts)

  defp call(pid, operation, opts) do
    actor = Reader.actor!(opts)
    GenServer.call(pid, {operation, actor.id}, 60_000)
  rescue
    error -> {:error, error}
  catch
    :exit, _reason -> {:error, :job_unavailable}
  end

  @impl true
  def init(opts) do
    opts = Backfill.options!(opts)
    actor = Reader.actor!(opts)

    {:ok, %{actor_id: actor.id, opts: opts, batch: nil, summary: %{status: :starting}},
     {:continue, :prepare}}
  end

  @impl true
  def handle_continue(:prepare, state) do
    batch = Backfill.prepare!(state.opts)
    send(self(), :next)
    {:noreply, %{state | opts: nil, batch: batch, summary: batch.summary}}
  rescue
    _error ->
      {:noreply,
       complete(%{state | opts: nil, summary: %{status: :failed, reason: :batch_failed}})}
  end

  @impl true
  def handle_info(:next, %{summary: %{status: :running}} = state) do
    case state.batch.pending_ids do
      [] ->
        batch = Backfill.finish(state.batch)
        {:noreply, complete(%{state | batch: nil, summary: batch.summary})}

      [_id | _rest] ->
        batch = Backfill.advance(state.batch)
        send(self(), :next)
        {:noreply, %{state | batch: batch, summary: batch.summary}}
    end
  end

  def handle_info(:next, state), do: {:noreply, state}
  def handle_info(:expire, state), do: {:stop, :normal, state}

  @impl true
  def handle_call({_operation, actor_id}, _from, state) when actor_id != state.actor_id do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call({:status, _actor_id}, _from, state), do: {:reply, {:ok, state.summary}, state}

  def handle_call({:cancel, _actor_id}, _from, state) do
    state =
      if state.summary.status in [:starting, :running] do
        remaining? = is_nil(state.batch) or state.batch.pending_ids != []

        summary =
          state.summary
          |> Map.put(:status, :canceled)
          |> Map.update(:has_more, remaining?, &(&1 or remaining?))

        complete(%{state | opts: nil, batch: nil, summary: summary})
      else
        state
      end

    {:reply, {:ok, state.summary}, state}
  end

  defp complete(state) do
    Process.send_after(self(), :expire, @retention_ms)
    state
  end
end
