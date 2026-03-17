defmodule IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor do
  @moduledoc """
  Backwards-compatible wrapper around `RequireRelatedAccessByActor`.

  New call sites should use `RequireRelatedAccessByActor` explicitly.
  """

  use Ash.Resource.Change

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  @impl true
  def change(changeset, opts, context) do
    RequireRelatedAccessByActor.change(
      changeset,
      Keyword.put_new(opts, :access, :writable),
      context
    )
  end
end
