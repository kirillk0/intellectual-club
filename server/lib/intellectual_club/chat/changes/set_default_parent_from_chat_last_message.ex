defmodule IntellectualClub.Chat.Changes.SetDefaultParentFromChatLastMessage do
  @moduledoc """
  Uses `chat.last_message_id` as parent when `parent_id` is not provided.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Chat.Chat

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      parent_id = Changeset.get_attribute(changeset, :parent_id)
      chat_id = Changeset.get_attribute(changeset, :chat_id)
      actor = changeset.context[:private][:actor]

      cond do
        not is_nil(parent_id) ->
          changeset

        not is_integer(chat_id) ->
          changeset

        true ->
          chat = Ash.get!(Chat, chat_id, actor: actor)
          Changeset.force_change_attribute(changeset, :parent_id, chat.last_message_id)
      end
    end)
  end
end
