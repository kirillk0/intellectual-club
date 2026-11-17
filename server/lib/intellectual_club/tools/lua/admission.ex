defmodule IntellectualClub.Tools.Lua.Admission do
  @moduledoc "Bounds whole driver calls, including database lock waits, without moving transactions to workers."
  use GenServer
  alias IntellectualClub.Tools.Lua.Limits

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def with_slot(owner, callback) do
    case GenServer.call(__MODULE__, {:acquire, owner}) do
      {:ok, ref} ->
        try do
          callback.()
        after
          GenServer.call(__MODULE__, {:release, ref})
        end

      error ->
        error
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:acquire, owner}, {caller, _tag}, slots) do
    if map_size(slots) >= Limits.get(:max_concurrent) or
         Enum.count(slots, fn {_ref, slot} -> slot.owner == owner end) >=
           Limits.get(:max_per_user) do
      {:reply, {:error, "Lua execution capacity reached; try again later."}, slots}
    else
      ref = Process.monitor(caller)
      {:reply, {:ok, ref}, Map.put(slots, ref, %{owner: owner, caller: caller})}
    end
  end

  def handle_call({:release, ref}, {caller, _tag}, slots) do
    case Map.get(slots, ref) do
      %{caller: ^caller} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, Map.delete(slots, ref)}

      _ ->
        {:reply, :ok, slots}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, slots),
    do: {:noreply, Map.delete(slots, ref)}
end
