defmodule IntellectualClub.Chat.Changes.CleanupLinkedForks do
  @moduledoc false

  use Ash.Resource.Change
  alias IntellectualClub.Chat.LinkedForkCleanup

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.around_action(&LinkedForkCleanup.around_destroy/2)
    |> Ash.Changeset.before_action(&LinkedForkCleanup.prepare/1)
    |> Ash.Changeset.after_action(fn changeset, record ->
      LinkedForkCleanup.schedule_after_delete(changeset)
      {:ok, record}
    end)
  end
end
