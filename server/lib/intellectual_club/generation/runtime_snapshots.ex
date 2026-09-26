defmodule IntellectualClub.Generation.RuntimeSnapshots do
  @moduledoc """
  Owner-scoped, node-local UI snapshots, readable without the Worker mailbox.

  This is not an authorization boundary. BFF callers must authorize every request.
  Register from the Worker, retain the returned identity, and publish only its
  current serialized UI step. Never pass a Context or a persistable/raw trace.
  """

  use GenServer

  @step_fields ~w(id sequence created_at finished_at status response_final input_tokens output_tokens cached_input_tokens reasoning_tokens cost time_to_first_token_ms tokens_per_second)a
  @item_fields ~w(id sequence created_at type tool_call_item_id)a
  @content_fields ~w(id external_id sequence kind content_text content_text_truncated content_json media)a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(message_id) when is_integer(message_id) do
    call({:register, message_id})
  end

  def publish(message_id, identity, snapshot) when is_map(snapshot) do
    call({:publish, message_id, identity, ui_snapshot(snapshot)})
  end

  def remove(message_id, identity), do: call({:remove, message_id, identity})

  @doc "Reads locally or from the owner's node; RPC failure is never proof of absence."
  def read(message_id, owner) when is_pid(owner) do
    if node(owner) == node() do
      read_local(message_id, owner)
    else
      case :rpc.call(node(owner), __MODULE__, :read_local, [message_id, owner], 250) do
        {:ok, _snapshot} = result -> result
        :not_found -> :not_found
        _other -> {:error, :unavailable}
      end
    end
  end

  @doc false
  def read_local(message_id, owner) when node(owner) == node() do
    case :ets.lookup(__MODULE__, message_id) do
      [{^message_id, ^owner, _identity, snapshot}] ->
        if Process.alive?(owner), do: {:ok, snapshot}, else: :not_found

      _other ->
        :not_found
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, message_id}, {owner, _tag}, monitors) do
    monitors = discard(message_id, monitors)
    identity = Process.monitor(owner)
    snapshot = ui_snapshot(%{status: :generating, phase: :initializing, step: nil})
    :ets.insert(__MODULE__, {message_id, owner, identity, snapshot})
    {:reply, {:ok, identity}, Map.put(monitors, identity, message_id)}
  end

  def handle_call({:publish, message_id, identity, snapshot}, {owner, _tag}, monitors) do
    case :ets.lookup(__MODULE__, message_id) do
      [{^message_id, ^owner, ^identity, _old}] ->
        :ets.insert(__MODULE__, {message_id, owner, identity, snapshot})
        {:reply, :ok, monitors}

      _other ->
        {:reply, {:error, :stale_owner}, monitors}
    end
  end

  def handle_call({:remove, message_id, identity}, {owner, _tag}, monitors) do
    monitors =
      case :ets.lookup(__MODULE__, message_id) do
        [{^message_id, ^owner, ^identity, _snapshot}] -> discard(message_id, monitors)
        _other -> monitors
      end

    {:reply, :ok, monitors}
  end

  @impl true
  def handle_info({:DOWN, identity, :process, owner, _reason}, monitors) do
    {message_id, monitors} = Map.pop(monitors, identity)

    case :ets.lookup(__MODULE__, message_id) do
      [{^message_id, ^owner, ^identity, _snapshot}] -> :ets.delete(__MODULE__, message_id)
      _other -> :ok
    end

    {:noreply, monitors}
  end

  defp discard(message_id, monitors) do
    case :ets.lookup(__MODULE__, message_id) do
      [{^message_id, _owner, identity, _snapshot}] ->
        Process.demonitor(identity, [:flush])
        :ets.delete(__MODULE__, message_id)
        Map.delete(monitors, identity)

      _other ->
        monitors
    end
  end

  defp call(request) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp ui_snapshot(snapshot) do
    step = ui_step(Map.get(snapshot, :step))

    snapshot = %{
      status: Map.get(snapshot, :status, :generating),
      phase: Map.get(snapshot, :phase, :initializing),
      step: step
    }

    revision =
      :crypto.hash(:sha256, :erlang.term_to_binary(snapshot, [:deterministic]))
      |> Base.url_encode64(padding: false)

    Map.put(snapshot, :revision, revision)
  end

  defp ui_step(nil), do: nil

  defp ui_step(step) when is_map(step) do
    items =
      step
      |> Map.get(:items, [])
      |> Enum.map(fn item ->
        contents =
          item
          |> Map.get(:contents, [])
          |> Enum.map(&Map.take(&1, @content_fields))

        item |> Map.take(@item_fields) |> Map.put(:contents, contents)
      end)

    step |> Map.take(@step_fields) |> Map.put(:items, items)
  end
end
