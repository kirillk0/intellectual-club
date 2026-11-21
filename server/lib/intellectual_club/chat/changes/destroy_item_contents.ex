defmodule IntellectualClub.Chat.Changes.DestroyItemContents do
  @moduledoc false
  use Ash.Resource.Change

  alias IntellectualClub.Chat.{ChatMessageContent, ChatMessageItem}

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      unless Ash.DataLayer.in_transaction?(ChatMessageItem) do
        raise ArgumentError, "Removing an item and its files requires a transaction"
      end

      id = changeset.data.id
      scope = Ash.Context.to_opts(context)

      # A new content row takes KEY SHARE on this item, not on its step.
      # Fence it first; a separate statement sees any writer that just committed.
      ChatMessageItem
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.select([:id])
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(scope)

      # Read file_id under the row lock: an UPDATE may attach a file to a
      # previously file-less row without acquiring a lock on the parent.
      contents =
        ChatMessageContent
        |> Ash.Query.filter(chat_message_item_id == ^id)
        |> Ash.Query.select([:id, :owner_id, :file_id])
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.lock(:for_update)
        |> Ash.read!(scope)

      if contents != [] do
        Ash.bulk_destroy!(
          contents,
          :destroy,
          %{},
          Keyword.merge(scope, strategy: [:stream], return_errors?: true)
        )
      end

      changeset
    end)
  end
end
