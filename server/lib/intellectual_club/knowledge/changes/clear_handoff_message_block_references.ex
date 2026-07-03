defmodule IntellectualClub.Knowledge.Changes.ClearHandoffMessageBlockReferences do
  @moduledoc """
  Clears bot handoff-message references before a knowledge block is deleted.
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Repo

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      block_id = changeset.data.id
      owner_id = changeset.data.owner_id

      clear_bot_handoff_references(block_id, owner_id)

      changeset
    end)
  end

  defp clear_bot_handoff_references(block_id, owner_id)
       when is_integer(block_id) and is_integer(owner_id) do
    _ =
      Repo.update_all(
        from(bot in "bots",
          where: bot.handoff_message_block_id == ^block_id and bot.owner_id == ^owner_id
        ),
        set: [handoff_message_block_id: nil]
      )

    :ok
  end

  defp clear_bot_handoff_references(_block_id, _owner_id), do: :ok
end
