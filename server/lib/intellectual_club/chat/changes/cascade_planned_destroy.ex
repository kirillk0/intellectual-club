defmodule IntellectualClub.Chat.Changes.CascadePlannedDestroy do
  @moduledoc """
  Forwards the current cleanup capability, unlike the generic cascade change
  whose scope is captured before the root's around-action hook prepares it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      IntellectualClub.Chat.LinkedForkCleanup.cascade(changeset, opts)
    end)
  end
end
