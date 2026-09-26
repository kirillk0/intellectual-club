defmodule IntellectualClub.Chat.Changes.ValidateStepRequest do
  @moduledoc false

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Generation.StepRequests.{Codec, Error, Storage}

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      try do
        fields = [:sequence, :chat_message_id] ++ Codec.fields()
        step = Map.new(fields, &{&1, Changeset.get_attribute(changeset, &1)})
        actor = changeset.context[:private][:actor]

        attrs =
          Storage.validate_create!(step, actor, Changeset.get_argument(changeset, :request_base))

        Changeset.force_change_attributes(changeset, attrs)
      rescue
        error in Error ->
          Changeset.add_error(changeset, field: :raw_request, message: Exception.message(error))
      end
    end)
  end
end
