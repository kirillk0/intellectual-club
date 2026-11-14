defmodule IntellectualClub.Chat.Changes.UnarchiveOnGenerationStart do
  @moduledoc "Returns a chat to the inbox when an assistant generation starts."
  use Ash.Resource.Change

  alias IntellectualClub.Chat.ReadState
  require Ash.Query

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    Ash.Changeset.after_action(changeset, fn changeset, message ->
      started? =
        message.role == :assistant and message.status == :generating and
          (changeset.action_type == :create or
             Ash.Changeset.changing_attribute?(changeset, :status))

      if started? do
        ReadState
        |> Ash.Query.filter(chat_id == ^message.chat_id and not is_nil(archived_revision))
        |> Ash.bulk_update!(:unarchive_for_generation, %{},
          actor: actor,
          authorize?: true,
          # The chat owner's update policy also covers shared viewers' archives.
          authorize_query?: false,
          strategy: :atomic,
          return_errors?: true
        )
      end

      {:ok, message}
    end)
  end
end
