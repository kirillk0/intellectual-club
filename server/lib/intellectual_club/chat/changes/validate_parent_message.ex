defmodule IntellectualClub.Chat.Changes.ValidateParentMessage do
  @moduledoc """
  Validates that `parent_id` belongs to the same chat.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Chat.ChatMessage

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      parent_id = Changeset.get_attribute(changeset, :parent_id)
      chat_id = Changeset.get_attribute(changeset, :chat_id) || changeset.data.chat_id
      actor = changeset.context[:private][:actor]

      cond do
        is_nil(parent_id) ->
          changeset

        is_nil(chat_id) ->
          Changeset.add_error(changeset, field: :chat_id, message: "is required")

        true ->
          case Ash.get(ChatMessage, parent_id, actor: actor) do
            {:ok, parent} ->
              if parent.chat_id == chat_id do
                changeset
              else
                Changeset.add_error(changeset,
                  field: :parent_id,
                  message: "must belong to the same chat"
                )
              end

            {:error, _error} ->
              Changeset.add_error(changeset,
                field: :parent_id,
                message: "is invalid or not accessible"
              )
          end
      end
    end)
  end
end
