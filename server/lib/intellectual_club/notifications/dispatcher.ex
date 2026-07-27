defmodule IntellectualClub.Notifications.Dispatcher do
  @moduledoc """
  Async entry point for Web Push notification side effects.
  """

  require Logger

  alias IntellectualClub.Notifications

  def child_spec(_opts) do
    Task.Supervisor.child_spec(name: __MODULE__)
  end

  def notify_generation_finished(message_id, status, opts \\ [])
      when is_integer(message_id) and status in [:done, :error, :canceled] and is_list(opts) do
    start_child(fn ->
      Notifications.deliver_generation_finished(message_id, status, opts)
    end)
  end

  def suppress_generation_finished(message_id, status)
      when is_integer(message_id) and status in [:done, :error, :canceled] do
    start_child(fn ->
      Notifications.suppress_generation_finished(message_id, status)
    end)
  end

  @doc "Asynchronously retries durable generation events left pending by a process crash."
  @spec recover_generation_events() :: :ok
  def recover_generation_events do
    start_child(&recover_generation_events_once/0)
  end

  defp recover_generation_events_once do
    lock_name = {__MODULE__, :generation_event_recovery}

    case :global.register_name(lock_name, self()) do
      :yes ->
        try do
          Notifications.recover_pending_generation_events()
        after
          :global.unregister_name(lock_name)
        end

      :no ->
        :ok
    end
  end

  defp start_child(fun) when is_function(fun, 0) do
    if Application.get_env(:intellectual_club, :web_push_dispatch_async, true) do
      case Task.Supervisor.start_child(__MODULE__, fun) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to start web push dispatch task: #{inspect(reason)}")
          :ok
      end
    else
      _ = fun.()
      :ok
    end
  end
end
