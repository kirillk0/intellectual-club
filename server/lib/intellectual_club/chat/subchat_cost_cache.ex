defmodule IntellectualClub.Chat.SubchatCostCache do
  @moduledoc """
  Bounded, node-local phase snapshots. Values are not authorization decisions.

  Callers authorize their scope before every lookup and run all database work in
  the request process. Reservations coalesce concurrent misses without blocking
  unrelated messages or retaining a request-owned ETS table.
  """

  use GenServer

  @ttl_ms :timer.minutes(30)
  @max_entries 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Fetches values for a map of identity => revision, loading only cache misses.
  """
  def fetch_many(requests, loader, opts \\ [])

  def fetch_many(requests, _loader, _opts) when requests == %{}, do: %{}

  def fetch_many(requests, loader, opts) when is_map(requests) do
    server = Keyword.get(opts, :cache, __MODULE__)
    refresh? = Keyword.get(opts, :refresh?, false)

    case GenServer.call(server, {:checkout, requests, refresh?}, :infinity) do
      :retry ->
        fetch_many(requests, loader, opts)

      {:cached, values} ->
        values

      {:load, token, hits, misses} ->
        try do
          values = loader.(Map.keys(misses))
          :ok = GenServer.call(server, {:store, token, values})
          Map.merge(hits, values)
        after
          GenServer.call(server, {:release, token})
        end
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       pending: %{},
       busy: MapSet.new(),
       waiters: [],
       ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
       max_entries: Keyword.get(opts, :max_entries, @max_entries)
     }}
  end

  @impl true
  def handle_call({:checkout, requests, refresh?}, {pid, _tag} = from, state) do
    if Enum.any?(Map.keys(requests), &MapSet.member?(state.busy, &1)) do
      {:noreply, %{state | waiters: [from | state.waiters]}}
    else
      now = System.monotonic_time(:millisecond)

      {hits, misses} =
        Enum.reduce(requests, {%{}, %{}}, fn {key, revision}, {hits, misses} ->
          case Map.get(state.entries, key) do
            %{revision: ^revision, value: value, expires_at: expires_at}
            when not refresh? and expires_at > now ->
              {Map.put(hits, key, value), misses}

            _other ->
              {hits, Map.put(misses, key, revision)}
          end
        end)

      if map_size(misses) == 0 do
        {:reply, {:cached, hits}, state}
      else
        token = Process.monitor(pid)

        state = %{
          state
          | pending: Map.put(state.pending, token, misses),
            busy: MapSet.union(state.busy, MapSet.new(Map.keys(misses)))
        }

        {:reply, {:load, token, hits, misses}, state}
      end
    end
  end

  def handle_call({:store, token, values}, _from, state) do
    now = System.monotonic_time(:millisecond)

    entries =
      Enum.reduce(Map.fetch!(state.pending, token), state.entries, fn {key, revision}, entries ->
        Map.put(entries, key, %{
          revision: revision,
          value: Map.fetch!(values, key),
          expires_at: now + state.ttl_ms
        })
      end)
      |> trim_entries(state.max_entries, now)

    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:release, token}, _from, state) do
    Process.demonitor(token, [:flush])
    {:reply, :ok, release(state, token)}
  end

  @impl true
  def handle_info({:DOWN, token, :process, _pid, _reason}, state) do
    {:noreply, release(state, token)}
  end

  defp release(state, token) do
    {requests, pending} = Map.pop(state.pending, token, %{})
    Enum.each(state.waiters, &GenServer.reply(&1, :retry))

    %{
      state
      | pending: pending,
        busy: MapSet.difference(state.busy, MapSet.new(Map.keys(requests))),
        waiters: []
    }
  end

  defp trim_entries(entries, max_entries, _now) when map_size(entries) <= max_entries,
    do: entries

  defp trim_entries(entries, max_entries, now) do
    entries
    |> Enum.filter(fn {_key, entry} -> entry.expires_at > now end)
    |> Enum.sort_by(fn {_key, entry} -> entry.expires_at end, :desc)
    |> Enum.take(max_entries)
    |> Map.new()
  end
end
