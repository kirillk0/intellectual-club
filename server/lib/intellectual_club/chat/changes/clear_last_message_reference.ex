defmodule IntellectualClub.Chat.Changes.ClearLastMessageReference do
  @moduledoc """
  Clears `last_message_id` before chat deletion.

  The chat row holds a foreign key to `chat_messages.id`, so the reference must
  be nulled before message cascades can remove the pointed record.
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Db

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      repo = Db.repo()
      chat_id = changeset.data.id
      actor = changeset.context[:private][:actor]

      owner_id =
        case actor do
          %{id: id} when is_integer(id) -> id
          _ -> nil
        end

      clear_last_message(repo, chat_id, owner_id)

      changeset
    end)
  end

  defp clear_last_message(repo, chat_id, owner_id) when is_integer(owner_id) do
    repo.update_all(
      from(c in "chats", where: c.id == ^chat_id and c.owner_id == ^owner_id),
      set: [last_message_id: nil]
    )

    :ok
  end

  defp clear_last_message(_repo, _chat_id, _owner_id), do: :ok
end
