defmodule IntellectualClub.Files.GarbageCollector do
  @moduledoc false

  use GenServer

  alias IntellectualClub.Files.File
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Files.PayloadLock

  require Ash.Query
  require Logger

  @default_interval_ms 3_600_000
  @minimum_retry_ms 1_000

  defstruct [:interval_ms, enabled: true, failure_count: 0]

  @type option ::
          {:name, GenServer.name() | nil}
          | {:enabled, boolean()}
          | {:interval_ms, pos_integer()}

  @type stats :: %{
          scanned: non_neg_integer(),
          deleted: non_neg_integer(),
          retained: non_neg_integer()
        }

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_server_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  @spec request_collection(String.t()) :: :ok
  def request_collection(sha256) when is_binary(sha256) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:collect, sha256})
    end

    :ok
  end

  def request_collection(_sha256), do: :ok

  @spec collect() :: {:ok, stats()} | {:error, term()}
  def collect do
    with {:ok, sha256s} <- FilesystemStorage.list_payload_sha256s() do
      {stats, errors} =
        Enum.reduce(
          sha256s,
          {%{scanned: 0, deleted: 0, retained: 0}, []},
          fn sha256, {stats, errors} ->
            stats = %{stats | scanned: stats.scanned + 1}

            case collect_sha256(sha256) do
              {:ok, :deleted} -> {%{stats | deleted: stats.deleted + 1}, errors}
              {:ok, :retained} -> {%{stats | retained: stats.retained + 1}, errors}
              {:error, reason} -> {stats, [{sha256, reason} | errors]}
            end
          end
        )

      case errors do
        [] -> {:ok, stats}
        errors -> {:error, {:payload_collection_failed, stats, Enum.reverse(errors)}}
      end
    end
  end

  @doc false
  @spec collect_sha256(String.t()) :: {:ok, :deleted | :retained} | {:error, term()}
  def collect_sha256(sha256) when is_binary(sha256) do
    File
    |> Ash.transact(
      fn ->
        with :ok <- PayloadLock.acquire(sha256),
             {:ok, referenced?} <- payload_referenced?(sha256) do
          if referenced? do
            :retained
          else
            with :ok <- FilesystemStorage.delete(sha256) do
              :deleted
            end
          end
        end
      end,
      return_notifications?: true
    )
    |> case do
      {:ok, status, _notifications} when status in [:deleted, :retained] -> {:ok, status}
      {:error, error} -> {:error, error}
    end
  end

  def collect_sha256(_sha256), do: {:error, :invalid_sha256}

  @impl true
  def init(opts) do
    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:intellectual_club, :file_gc_enabled, true)
      )

    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:intellectual_club, :file_gc_interval_ms, @default_interval_ms)
      )

    state = %__MODULE__{
      enabled: enabled == true,
      interval_ms: normalize_interval(interval_ms)
    }

    if state.enabled, do: schedule_collection(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:collect, _sha256}, %{enabled: false} = state), do: {:noreply, state}

  def handle_cast({:collect, sha256}, state) do
    case safe_collect_sha256(sha256) do
      {:ok, _status} ->
        {:noreply, %{state | failure_count: 0}}

      {:error, reason} ->
        Logger.warning("File payload collection failed sha256=#{sha256}: #{inspect(reason)}")
        {:noreply, %{state | failure_count: state.failure_count + 1}}
    end
  end

  @impl true
  def handle_info(:collect, state) do
    state =
      case safe_collect() do
        {:ok, _stats} ->
          %{state | failure_count: 0}

        {:error, reason} ->
          Logger.warning("File payload garbage collection failed: #{inspect(reason)}")
          %{state | failure_count: state.failure_count + 1}
      end

    if state.enabled do
      schedule_collection(next_delay(state))
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp payload_referenced?(sha256) do
    File
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.exists(authorize?: false)
  end

  defp safe_collect do
    collect()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_collect_sha256(sha256) do
    collect_sha256(sha256)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp next_delay(%__MODULE__{failure_count: 0, interval_ms: interval_ms}), do: interval_ms

  defp next_delay(%__MODULE__{failure_count: failure_count, interval_ms: interval_ms}) do
    retry_ms =
      @minimum_retry_ms *
        trunc(:math.pow(2, min(max(failure_count - 1, 0), 8)))

    min(interval_ms, retry_ms)
  end

  defp schedule_collection(delay_ms) do
    Process.send_after(self(), :collect, delay_ms)
  end

  defp normalize_interval(value) when is_integer(value) and value > 0, do: value
  defp normalize_interval(_value), do: @default_interval_ms
end
