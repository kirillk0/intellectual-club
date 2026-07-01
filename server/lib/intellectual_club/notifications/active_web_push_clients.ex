defmodule IntellectualClub.Notifications.ActiveWebPushClients do
  @moduledoc """
  Tracks visible browser clients that should suppress local Web Push notifications.
  """

  use GenServer

  @ttl_ms 45_000
  @seen_ttl_ms 60_000
  @prune_interval_ms 15_000

  defstruct clients: %{}, seen_generations: %{}, ttl_ms: @ttl_ms, seen_ttl_ms: @seen_ttl_ms

  @type key :: {String.t(), String.t()}
  @type client :: %{owner_id: integer(), chat_id: integer(), last_seen_at: integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec upsert(integer(), String.t(), String.t(), integer()) :: :ok
  def upsert(owner_id, endpoint, client_id, chat_id)
      when is_integer(owner_id) and is_binary(endpoint) and is_binary(client_id) and
             is_integer(chat_id) do
    GenServer.call(__MODULE__, {:upsert, owner_id, endpoint, client_id, chat_id})
  end

  @spec remove(String.t(), String.t()) :: :ok
  def remove(endpoint, client_id) when is_binary(endpoint) and is_binary(client_id) do
    GenServer.call(__MODULE__, {:remove, endpoint, client_id})
  end

  @spec remove_endpoint(String.t()) :: :ok
  def remove_endpoint(endpoint) when is_binary(endpoint) do
    GenServer.call(__MODULE__, {:remove_endpoint, endpoint})
  end

  @spec active?(integer(), String.t(), integer()) :: boolean()
  def active?(owner_id, endpoint, chat_id)
      when is_integer(owner_id) and is_binary(endpoint) and is_integer(chat_id) do
    GenServer.call(__MODULE__, {:active?, owner_id, endpoint, chat_id})
  end

  @spec record_generation_seen(integer(), integer(), integer(), :done | :error) :: :ok
  def record_generation_seen(owner_id, chat_id, message_id, status)
      when is_integer(owner_id) and is_integer(chat_id) and is_integer(message_id) and
             status in [:done, :error] do
    GenServer.call(__MODULE__, {:record_generation_seen, owner_id, chat_id, message_id, status})
  end

  @spec generation_seen?(integer(), integer(), integer(), :done | :error) :: boolean()
  def generation_seen?(owner_id, chat_id, message_id, status)
      when is_integer(owner_id) and is_integer(chat_id) and is_integer(message_id) and
             status in [:done, :error] do
    GenServer.call(__MODULE__, {:generation_seen?, owner_id, chat_id, message_id, status})
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(opts) do
    schedule_prune()

    {:ok,
     %__MODULE__{
       ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
       seen_ttl_ms: Keyword.get(opts, :seen_ttl_ms, @seen_ttl_ms)
     }}
  end

  @impl true
  def handle_call({:upsert, owner_id, endpoint, client_id, chat_id}, _from, state) do
    now = now_ms()

    clients =
      state.clients
      |> prune_expired_clients(now, state.ttl_ms)
      |> Map.put({endpoint, client_id}, %{
        owner_id: owner_id,
        chat_id: chat_id,
        last_seen_at: now
      })

    {:reply, :ok, %{state | clients: clients}}
  end

  def handle_call({:remove, endpoint, client_id}, _from, state) do
    {:reply, :ok, %{state | clients: Map.delete(state.clients, {endpoint, client_id})}}
  end

  def handle_call({:remove_endpoint, endpoint}, _from, state) do
    clients =
      state.clients
      |> Enum.reject(fn {{client_endpoint, _client_id}, _client} ->
        client_endpoint == endpoint
      end)
      |> Map.new()

    {:reply, :ok, %{state | clients: clients}}
  end

  def handle_call({:active?, owner_id, endpoint, chat_id}, _from, state) do
    now = now_ms()
    clients = prune_expired_clients(state.clients, now, state.ttl_ms)

    active? =
      Enum.any?(clients, fn
        {{^endpoint, _client_id}, %{owner_id: ^owner_id, chat_id: ^chat_id}} -> true
        _other -> false
      end)

    {:reply, active?, %{state | clients: clients}}
  end

  def handle_call(
        {:record_generation_seen, owner_id, chat_id, message_id, status},
        _from,
        state
      ) do
    now = now_ms()

    seen_generations =
      state.seen_generations
      |> prune_expired_timestamps(now, state.seen_ttl_ms)
      |> Map.put({owner_id, chat_id, message_id, status}, now)

    {:reply, :ok, %{state | seen_generations: seen_generations}}
  end

  def handle_call({:generation_seen?, owner_id, chat_id, message_id, status}, _from, state) do
    now = now_ms()
    seen_generations = prune_expired_timestamps(state.seen_generations, now, state.seen_ttl_ms)
    key = {owner_id, chat_id, message_id, status}

    {:reply, Map.has_key?(seen_generations, key), %{state | seen_generations: seen_generations}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | clients: %{}, seen_generations: %{}}}
  end

  @impl true
  def handle_info(:prune, state) do
    schedule_prune()
    now = now_ms()

    {:noreply,
     %{
       state
       | clients: prune_expired_clients(state.clients, now, state.ttl_ms),
         seen_generations:
           prune_expired_timestamps(state.seen_generations, now, state.seen_ttl_ms)
     }}
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp prune_expired_clients(clients, now, ttl_ms) do
    clients
    |> Enum.reject(fn {_key, %{last_seen_at: last_seen_at}} -> now - last_seen_at > ttl_ms end)
    |> Map.new()
  end

  defp prune_expired_timestamps(items, now, ttl_ms) do
    items
    |> Enum.reject(fn {_key, last_seen_at} -> now - last_seen_at > ttl_ms end)
    |> Map.new()
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
