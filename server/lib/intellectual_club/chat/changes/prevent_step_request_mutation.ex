defmodule IntellectualClub.Chat.Changes.PreventStepRequestMutation do
  @moduledoc false

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Generation.StepRequests.Codec

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      fields = [:sequence, :owner_id, :chat_message_id] ++ Codec.fields()

      Enum.reduce(fields, changeset, fn field, changeset ->
        if Map.has_key?(changeset.attributes, field) or Keyword.has_key?(changeset.atomics, field) do
          Changeset.add_error(changeset, field: field, message: "is immutable")
        else
          changeset
        end
      end)
    end)
  end
end
