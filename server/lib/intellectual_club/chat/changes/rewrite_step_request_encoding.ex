defmodule IntellectualClub.Chat.Changes.RewriteStepRequestEncoding do
  @moduledoc false

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Generation.StepRequests.{Error, Storage}

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      try do
        # No context flag, caller-supplied original, or bypass token is trusted.
        if Map.keys(changeset.attributes) -- [:updated_at] != [] or changeset.atomics != [],
          do: raise(Error, reason: :invalid_rewrite_fields)

        actor = changeset.context[:private][:actor]
        encoding = Changeset.get_argument(changeset, :encoding)
        {attrs, updated_at} = Storage.validate_rewrite!(changeset.data.id, encoding, actor)

        changeset
        |> Changeset.force_change_attributes(attrs)
        |> Changeset.atomic_update(:updated_at, updated_at)
      rescue
        error in Error ->
          Changeset.add_error(changeset, field: :encoding, message: Exception.message(error))
      end
    end)
  end
end
