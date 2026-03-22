defmodule IntellectualClub.Chat.Changes.DeleteChatDependents do
  @moduledoc """
  Deletes dependent chat records before the chat itself is destroyed.

  This is necessary because the database schema currently uses non-cascading
  foreign keys:
  - `chat_messages.chat_id -> chats.id`
  - `chat_message_steps.chat_message_id -> chat_messages.id`
  - `chat_message_items.chat_message_step_id -> chat_message_steps.id`
  - `chat_message_contents.chat_message_item_id -> chat_message_items.id`
  - `chat_knowledge_blocks.chat_id -> chats.id`
  - `chat_tool_bindings.chat_id -> chats.id`
  - `chats.last_message_id -> chat_messages.id`

  Without cleaning up dependents (and clearing `last_message_id`) first, a chat
  delete can fail with FK constraint errors.
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
      delete_chat_knowledge_blocks(repo, chat_id, owner_id)
      delete_chat_tool_bindings(repo, chat_id, owner_id)
      delete_chat_messages_tree(repo, chat_id, owner_id)

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

  defp delete_chat_knowledge_blocks(repo, chat_id, owner_id) when is_integer(owner_id) do
    repo.delete_all(
      from(kb in "chat_knowledge_blocks",
        where: kb.chat_id == ^chat_id and kb.owner_id == ^owner_id
      )
    )

    :ok
  end

  defp delete_chat_knowledge_blocks(_repo, _chat_id, _owner_id), do: :ok

  defp delete_chat_tool_bindings(repo, chat_id, owner_id) when is_integer(owner_id) do
    repo.delete_all(
      from(tb in "chat_tool_bindings",
        where: tb.chat_id == ^chat_id and tb.owner_id == ^owner_id
      )
    )

    :ok
  end

  defp delete_chat_tool_bindings(_repo, _chat_id, _owner_id), do: :ok

  defp delete_chat_messages_tree(repo, chat_id, owner_id) when is_integer(owner_id) do
    message_ids =
      from(m in "chat_messages",
        where: m.chat_id == ^chat_id and m.owner_id == ^owner_id,
        select: m.id
      )

    step_ids =
      from(s in "chat_message_steps",
        where: s.chat_message_id in subquery(message_ids) and s.owner_id == ^owner_id,
        select: s.id
      )

    item_ids =
      from(i in "chat_message_items",
        where: i.chat_message_step_id in subquery(step_ids) and i.owner_id == ^owner_id,
        select: i.id
      )

    _ =
      repo.delete_all(
        from(c in "chat_message_contents",
          where: c.chat_message_item_id in subquery(item_ids) and c.owner_id == ^owner_id
        )
      )

    _ =
      repo.delete_all(
        from(i in "chat_message_items",
          where: i.chat_message_step_id in subquery(step_ids) and i.owner_id == ^owner_id
        )
      )

    _ =
      repo.delete_all(
        from(s in "chat_message_steps",
          where: s.chat_message_id in subquery(message_ids) and s.owner_id == ^owner_id
        )
      )

    _ =
      repo.delete_all(
        from(m in "chat_messages", where: m.chat_id == ^chat_id and m.owner_id == ^owner_id)
      )

    :ok
  end

  defp delete_chat_messages_tree(_repo, _chat_id, _owner_id), do: :ok
end
