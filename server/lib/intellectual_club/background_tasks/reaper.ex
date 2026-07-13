defmodule IntellectualClub.BackgroundTasks.Reaper do
  @moduledoc false

  use GenServer

  alias IntellectualClub.BackgroundTasks

  require Logger

  @default_interval_ms 2_000
  @minimum_retry_ms 100

  defstruct [:interval_ms, enabled: true, failure_count: 0]

  @type option ::
          {:name, GenServer.name() | nil}
          | {:enabled, boolean()}
          | {:interval_ms, pos_integer()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_server_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  @spec sweep(GenServer.server()) :: :ok | {:error, term()}
  def sweep(server \\ __MODULE__) do
    GenServer.call(server, :sweep, :infinity)
  end

  @impl true
  def init(opts) do
    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:intellectual_club, :background_task_reaper_enabled, true)
      )

    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(
          :intellectual_club,
          :background_task_reaper_interval_ms,
          @default_interval_ms
        )
      )

    state = %__MODULE__{
      enabled: enabled == true,
      interval_ms: normalize_interval(interval_ms)
    }

    if state.enabled, do: schedule_sweep(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {result, state} = run_sweep(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    {_result, state} = run_sweep(state)

    if state.enabled do
      schedule_sweep(next_delay(state))
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_sweep(state) do
    case safe_sweep() do
      :ok ->
        {:ok, %{state | failure_count: 0}}

      {:error, reason} = error ->
        Logger.warning("Background task live reaper failed: #{inspect(reason)}")
        {error, %{state | failure_count: state.failure_count + 1}}
    end
  end

  defp safe_sweep do
    BackgroundTasks.reap_lost_workers()
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

  defp schedule_sweep(delay_ms) do
    Process.send_after(self(), :sweep, delay_ms)
  end

  defp normalize_interval(value) when is_integer(value) and value > 0, do: value
  defp normalize_interval(_value), do: @default_interval_ms
end
