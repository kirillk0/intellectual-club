defmodule IntellectualClub.Chat.ChatActivityNotifier do
  @moduledoc "Emits lightweight inbox invalidations after assistant status writes."
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{data: message, action: action, changeset: changeset}) do
    status_changed? =
      action.type == :create or
        (action.type == :update and Ash.Changeset.changing_attribute?(changeset, :status))

    if message.role == :assistant and status_changed? do
      IntellectualClub.Chat.ReadStateEvents.publish(message.owner_id, message.chat_id)
    end

    :ok
  end
end
