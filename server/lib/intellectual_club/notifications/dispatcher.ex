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
      when is_integer(message_id) and status in [:done, :error] and is_list(opts) do
    start_child(fn ->
      Notifications.deliver_generation_finished(message_id, status, opts)
    end)
  end

  def suppress_generation_finished(message_id, status)
      when is_integer(message_id) and status in [:done, :error] do
    start_child(fn ->
      Notifications.suppress_generation_finished(message_id, status)
    end)
  end

  defp start_child(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(__MODULE__, fun) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to start web push dispatch task: #{inspect(reason)}")
        :ok
    end
  end
end
