defmodule IntellectualClub.Chat.Changes.RestrictLinkedForkMutations do
  @moduledoc """
  Restricts public message actions in live-linked forks to append-only history.

  Internal generation writes and cascade destroy_with_children remain separate
  actions. Ordinary chats and legacy copied forks keep their existing semantics.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Chat.Chat

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    mode = Keyword.fetch!(opts, :mode)
    Changeset.before_action(changeset, &restrict(&1, mode))
  end

  defp restrict(changeset, mode) do
    actor = changeset.context[:private][:actor]
    chat_id = Changeset.get_attribute(changeset, :chat_id)

    with {:ok, %Chat{} = chat} <- Ash.get(Chat, chat_id, actor: actor) do
      if is_nil(chat.fork_task) do
        changeset
      else
        restrict_linked(changeset, mode, chat, actor)
      end
    else
      _other -> Changeset.add_error(changeset, field: :chat_id, message: "is not accessible")
    end
  end

  defp restrict_linked(changeset, :destroy, _chat, _actor), do: read_only(changeset)

  defp restrict_linked(changeset, :append, chat, actor) do
    # Serialize appends without blocking generation usage inserts via the chat FK.
    chat =
      Chat
      |> Ash.Query.filter(id == ^chat.id)
      |> Ash.Query.lock("FOR NO KEY UPDATE")
      |> Ash.read_one!(actor: actor)

    parent_id = Changeset.get_attribute(changeset, :parent_id)
    use_active? = Changeset.get_argument(changeset, :use_active_leaf_parent) != false

    cond do
      is_nil(chat) ->
        read_only(changeset)

      is_nil(parent_id) and use_active? ->
        Changeset.force_change_attribute(changeset, :parent_id, chat.last_message_id)

      parent_id == chat.last_message_id ->
        changeset

      true ->
        read_only(changeset)
    end
  end

  defp read_only(changeset) do
    Changeset.add_error(changeset,
      message: "Linked fork history is read-only. Send a follow-up instead."
    )
  end
end
