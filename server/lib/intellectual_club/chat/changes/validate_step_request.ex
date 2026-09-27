defmodule IntellectualClub.Chat.Changes.ValidateStepRequest do
  @moduledoc false

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Generation.StepRequests.{Codec, Error, Storage}

  @impl true
  def change(changeset, opts, _context) do
    if opts[:logical?], do: prepare_logical(changeset), else: validate_physical(changeset)
  end

  defp validate_physical(changeset) do
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

  # Executed by for_create, before the caller starts publication and takes row
  # locks. The closure, not a caller-writable context flag/struct/hash, owns the
  # plan. Even an explicit snapshot argument would have to be normalized here.
  defp prepare_logical(changeset) do
    if changeset.valid? do
      actor = changeset.context[:private][:actor]
      identity = attributes(changeset, [:chat_message_id, :sequence, :owner_id])
      input = Changeset.get_argument(changeset, :request)
      initial_fields = attributes(changeset, Codec.fields())
      arguments = changeset.arguments

      plan =
        Storage.prepare_logical_create!(identity, input, actor,
          previous_request: Changeset.get_argument(changeset, :request_base),
          previous_step_id: Changeset.get_argument(changeset, :request_base_step_id),
          force_full: Changeset.get_argument(changeset, :force_full),
          max_chain: Changeset.get_argument(changeset, :max_chain)
        )

      changeset
      |> Changeset.set_context(%{step_request_snapshot: plan.snapshot})
      |> Changeset.before_action(fn current ->
        try do
          unless attributes(current, [:chat_message_id, :sequence, :owner_id]) == identity and
                   attributes(current, Codec.fields()) === initial_fields and
                   current.arguments === arguments and current.atomics == [],
                 do: raise(Error, reason: :logical_request_input_changed)

          actor = current.context[:private][:actor]
          attrs = Storage.verify_logical_create!(plan, actor)
          Changeset.force_change_attributes(current, attrs)
        rescue
          error in Error -> request_error(current, error)
        end
      end)
    else
      changeset
    end
  rescue
    error in Error -> request_error(changeset, error)
  end

  defp attributes(changeset, fields),
    do: Map.new(fields, &{&1, Changeset.get_attribute(changeset, &1)})

  defp request_error(changeset, error),
    do: Changeset.add_error(changeset, field: :request, message: Exception.message(error))
end
