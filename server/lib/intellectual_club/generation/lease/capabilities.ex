defmodule IntellectualClub.Generation.Lease.Capabilities do
  @moduledoc false

  # Only the manager writes this table; its lifetime is the manager's lifetime.
  # A restarted manager must never resurrect a previous manager's capability.
  def create do
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
  end

  def put(%{manager: manager, message_id: message_id, ref: ref, fence_token: token}) do
    :ets.insert(__MODULE__, {{manager, message_id}, ref, token})
  end

  def delete(manager, message_id) do
    :ets.delete(__MODULE__, {manager, message_id})
  rescue
    ArgumentError -> :ok
  end

  def active?(%{manager: manager, message_id: message_id, ref: ref, fence_token: token}) do
    :ets.lookup(__MODULE__, {manager, message_id}) == [{{manager, message_id}, ref, token}]
  rescue
    # Do not fall back to a same-node RPC or recreate an absent table. Losing
    # local capability state is a fence loss, not permission to keep writing.
    ArgumentError -> false
  end
end
