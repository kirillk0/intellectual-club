defmodule IntellectualClub.BackgroundTasks.Registry do
  @moduledoc """
  Maps persisted adapter names to implementation modules.
  """

  alias IntellectualClub.BackgroundTasks.Adapters.Ssh
  alias IntellectualClub.Chat.Fork
  alias IntellectualClub.Chat.Spawn
  alias IntellectualClub.Tools.Drivers.Outlet

  @spec fetch(String.t() | atom()) :: {:ok, module()} | {:error, :unknown_adapter}
  def fetch(adapter) do
    case adapter |> to_string() |> String.trim() do
      "ssh" -> {:ok, Ssh}
      "fork" -> {:ok, Fork}
      "spawn" -> {:ok, Spawn}
      "outlet" -> {:ok, Outlet}
      _other -> {:error, :unknown_adapter}
    end
  end

  @spec fetch!(String.t() | atom()) :: module()
  def fetch!(adapter) do
    case fetch(adapter) do
      {:ok, module} -> module
      {:error, :unknown_adapter} -> raise ArgumentError, "Unknown background adapter: #{adapter}"
    end
  end
end
