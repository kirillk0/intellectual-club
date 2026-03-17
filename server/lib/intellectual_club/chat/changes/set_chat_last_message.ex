defmodule IntellectualClub.Chat.Changes.SetChatLastMessage do
  @moduledoc """
  Updates `chat.last_message_id` after a message is created.
  """

  use Ash.Resource.Change

  alias IntellectualClub.Chat.Chat

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, message ->
      actor = changeset.context[:private][:actor]

      chat = Ash.get!(Chat, message.chat_id, actor: actor)

      case chat
           |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: message.id},
             actor: actor
           )
           |> Ash.update() do
        {:ok, _chat} -> {:ok, message}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
