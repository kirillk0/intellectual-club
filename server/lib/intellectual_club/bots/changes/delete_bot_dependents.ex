defmodule IntellectualClub.Bots.Changes.DeleteBotDependents do
  @moduledoc """
  Cleans bot-dependent records before bot deletion.

  Database foreign keys are non-cascading for:
  - `bot_knowledge_blocks.bot_id -> bots.id`
  - `bot_tool_bindings.bot_id -> bots.id`
  - `bot_user_tool_bindings.bot_id -> bots.id`
  - `chats.bot_id -> bots.id`

  Before deleting a bot we remove bot-owned dependent rows, remove all
  per-user tool overrides for that bot, and clear `chats.bot_id` for the
  same owner.
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Repo

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      repo = Repo
      bot_id = changeset.data.id
      owner_id = actor_id(changeset.context[:private][:actor])

      delete_bot_knowledge_blocks(repo, bot_id, owner_id)
      delete_bot_tool_bindings(repo, bot_id, owner_id)
      delete_bot_user_tool_bindings(repo, bot_id)
      clear_chat_bot_reference(repo, bot_id, owner_id)

      changeset
    end)
  end

  defp actor_id(%{id: id}) when is_integer(id), do: id
  defp actor_id(_), do: nil

  defp delete_bot_knowledge_blocks(repo, bot_id, owner_id) when is_integer(owner_id) do
    _ =
      repo.delete_all(
        from(bkb in "bot_knowledge_blocks",
          where: bkb.bot_id == ^bot_id and bkb.owner_id == ^owner_id
        )
      )

    :ok
  end

  defp delete_bot_knowledge_blocks(_repo, _bot_id, _owner_id), do: :ok

  defp delete_bot_tool_bindings(repo, bot_id, owner_id) when is_integer(owner_id) do
    _ =
      repo.delete_all(
        from(btb in "bot_tool_bindings",
          where: btb.bot_id == ^bot_id and btb.owner_id == ^owner_id
        )
      )

    :ok
  end

  defp delete_bot_tool_bindings(_repo, _bot_id, _owner_id), do: :ok

  defp delete_bot_user_tool_bindings(repo, bot_id) when is_integer(bot_id) do
    _ =
      repo.delete_all(from(butb in "bot_user_tool_bindings", where: butb.bot_id == ^bot_id))

    :ok
  end

  defp delete_bot_user_tool_bindings(_repo, _bot_id), do: :ok

  defp clear_chat_bot_reference(repo, bot_id, owner_id) when is_integer(owner_id) do
    _ =
      repo.update_all(
        from(c in "chats", where: c.bot_id == ^bot_id and c.owner_id == ^owner_id),
        set: [bot_id: nil]
      )

    :ok
  end

  defp clear_chat_bot_reference(_repo, _bot_id, _owner_id), do: :ok
end
