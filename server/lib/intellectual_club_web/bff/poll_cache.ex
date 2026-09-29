defmodule IntellectualClubWeb.Bff.PollCache do
  @moduledoc """
  Bounded, disposable payload values, never authorization decisions.

  All loading and permission checks run in the request, not this process. A cache
  restart or eviction changes performance only. One revision per actor/selection
  is retained; entries expire after five minutes and have a total byte budget.
  """
  use GenServer

  @ttl_ms :timer.minutes(5)
  @max_entries 256
  @max_bytes 16 * 1024 * 1024
  @max_entry_bytes 2 * 1024 * 1024

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def fetch(key, revision, loader) when is_function(loader, 0) do
    case lookup(key, revision) do
      {:ok, value} ->
        value

      :miss ->
        value = loader.()
        store(key, revision, value)
        value
    end
  end

  defp lookup(key, revision) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, key) do
      [{^key, ^revision, value, expires_at, _bytes}] when expires_at > now -> {:ok, value}
      _other -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(key, revision, value) do
    bytes = :erlang.external_size(value)

    if bytes <= @max_entry_bytes,
      do: GenServer.call(__MODULE__, {:store, key, revision, value, bytes})

    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:store, key, revision, value, bytes}, _from, state) do
    now = System.monotonic_time(:millisecond)
    :ets.insert(__MODULE__, {key, revision, value, now + @ttl_ms, bytes})

    __MODULE__
    |> :ets.select([{{:"$1", :_, :_, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.sort_by(fn {_key, expires, _bytes} -> expires end, :desc)
    |> Enum.reduce({0, 0}, fn {entry_key, expires, size}, {count, total} ->
      if expires > now and count < @max_entries and total + size <= @max_bytes do
        {count + 1, total + size}
      else
        :ets.delete(__MODULE__, entry_key)
        {count, total}
      end
    end)

    {:reply, :ok, state}
  end
end
