defmodule IntellectualClub.Chat.Changes.DeleteChatSharesOnAccessBoundaryChange do
  @moduledoc """
  Clears chat shares when the chat stops matching the validated share boundary.
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [from: 2]

  alias Ash.Changeset
  alias IntellectualClub.Db

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.after_action(changeset, fn changeset, chat ->
      if clear_required?(changeset) do
        delete_chat_shares(chat.id)
      end

      {:ok, chat}
    end)
  end

  defp clear_required?(changeset) do
    bot_changed? = Changeset.changing_attribute?(changeset, :bot_id)
    config_changed? = Changeset.changing_attribute?(changeset, :llm_configuration_id)
    chat_blocks_changed? = relationship_argument_present?(changeset, :knowledge_block_bindings)
    tools_changed? = relationship_argument_present?(changeset, :tool_bindings)

    bot_changed? or config_changed? or chat_blocks_changed? or tools_changed?
  end

  defp relationship_argument_present?(changeset, argument) do
    case Changeset.fetch_argument(changeset, argument) do
      {:ok, value} when is_list(value) -> value != []
      {:ok, nil} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  defp delete_chat_shares(chat_id) when is_integer(chat_id) do
    Db.repo().delete_all(from(s in "chat_shares", where: s.chat_id == ^chat_id))
    :ok
  end

  defp delete_chat_shares(_chat_id), do: :ok
end
