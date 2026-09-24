defmodule IntellectualClub.Chat.Changes.CascadeDestroyInCleanup do
  @moduledoc """
  Keeps ordinary relation cascades inside the cleanup around-action scope.

  Ash 3.29's bulk-to-single adapter wraps before_batch results with a notification
  list, whereas before_action expects an instructions map. Delegate only the stock
  per-record change so bulk/JSON API destroys do not enter that adapter. Related
  records still use the standard authorized cascade actions and file hooks.
  """
  use Ash.Resource.Change

  @impl true
  def batch_callbacks?(_changesets, _opts, _context), do: false

  @impl true
  def change(changeset, opts, context) do
    Ash.Resource.Change.CascadeDestroy.change(changeset, opts, context)
  end
end
