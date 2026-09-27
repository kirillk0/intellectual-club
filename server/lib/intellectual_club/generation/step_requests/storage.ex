defmodule IntellectualClub.Generation.StepRequests.Storage do
  @moduledoc false

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep}
  alias IntellectualClub.Generation.StepRequests.{Codec, Error, Reader}

  require Ash.Query

  @terminal_statuses [:done, :canceled, :error]
  @message_fields [:id, :chat_id, :owner_id, :role, :status]

  @base_fields [
    :id,
    :owner_id,
    :chat_message_id,
    :sequence,
    :request_mode,
    :request_hash,
    :request_checkpoint_distance
  ]

  @doc false
  def prepare_logical_create!(step, request, actor, opts) do
    actor = Reader.actor!(actor: actor)

    unless is_integer(step.sequence) and step.sequence > 0,
      do: raise(Error, reason: :invalid_sequence)

    known_base = Keyword.get(opts, :previous_request)
    expected_id = Keyword.get(opts, :previous_step_id)

    previous =
      if step.sequence > 1 and
           (not Keyword.get(opts, :force_full, false) or not is_nil(known_base) or
              not is_nil(expected_id)),
         do: previous_metadata(step.chat_message_id, step.sequence, actor)

    if expected_id && (is_nil(previous) or previous.id != expected_id),
      do: raise(Error, reason: :invalid_patch_base)

    if not is_nil(known_base) and is_nil(previous), do: raise(Error, reason: :missing_base)

    base =
      if previous do
        cond do
          not is_nil(known_base) and is_binary(previous.request_hash) ->
            candidate = Codec.snapshot!(known_base)

            unless candidate.hash == previous.request_hash,
              do: raise(Error, reason: :runtime_request_mismatch, step_id: previous.id)

            candidate

          true ->
            persisted = Reader.snapshots_for_steps!([previous.id], actor: actor)[previous.id]

            if not is_nil(known_base) do
              candidate =
                if known_base === persisted.request,
                  do: persisted,
                  else: Codec.snapshot!(known_base)

              unless candidate.hash == persisted.hash,
                do: raise(Error, reason: :runtime_request_mismatch, step_id: previous.id)

              candidate
            else
              persisted
            end
        end
      end

    snapshot =
      if base &&
           (request === base.request or (not is_nil(known_base) and request === known_base)),
         do: base,
         else: Codec.snapshot!(request)

    attrs =
      Codec.create_from_snapshots(snapshot,
        sequence: step.sequence,
        previous_step: previous,
        previous_snapshot: base,
        force_full: opts[:force_full] || false,
        max_chain: opts[:max_chain] || Codec.max_chain()
      )

    %{
      actor_id: actor.id,
      chat_message_id: step.chat_message_id,
      sequence: step.sequence,
      previous: if(previous, do: Map.take(previous, @base_fields)),
      attrs: attrs,
      snapshot: snapshot
    }
  end

  @doc false
  def verify_logical_create!(plan, actor) do
    actor = Reader.actor!(actor: actor)
    unless actor.id == plan.actor_id, do: raise(Error, reason: :actor_changed)
    require_transaction!()
    _message = lock_message!(plan.chat_message_id, actor, false)

    if plan.previous do
      previous = previous_metadata(plan.chat_message_id, plan.sequence, actor, true)

      unless previous && Map.take(previous, @base_fields) == plan.previous,
        do: raise(Error, reason: :request_base_changed)
    end

    plan.attrs
  end

  defp previous_metadata(message_id, sequence, actor, lock? \\ false) do
    previous_sequence = sequence - 1

    query =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^message_id and sequence == ^previous_sequence)
      |> Ash.Query.select(@base_fields)

    query = if lock?, do: Ash.Query.lock(query, "FOR SHARE"), else: query
    previous = Ash.read_one!(query, actor: actor, authorize?: true)

    if previous && previous.owner_id != actor.id,
      do: raise(Error, reason: :unsafe_step_owner, step_id: previous.id)

    previous
  end

  def validate_create!(step, actor, known_base \\ nil) do
    _actor = Reader.actor!(actor: actor)

    Codec.validate_encoding!(step, fn attrs ->
      require_transaction!()
      _message = lock_message!(step.chat_message_id, actor, false)
      validated_base!(Map.merge(step, attrs), actor, known_base)
    end)
  end

  defp validated_base!(step, actor, known_base)
       when is_map(known_base) and not is_struct(known_base) do
    previous_sequence = step.sequence - 1

    previous =
      ChatMessageStep
      |> Ash.Query.filter(
        chat_message_id == ^step.chat_message_id and sequence == ^previous_sequence
      )
      |> Ash.Query.select([
        :id,
        :chat_message_id,
        :sequence,
        :request_mode,
        :request_hash,
        :request_checkpoint_distance
      ])
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: actor, authorize?: true)

    unless previous, do: raise(Error, reason: :missing_base)

    if is_binary(previous.request_hash) do
      # Possession of a draft is not authority. Bind its claimed base hash to
      # locked persisted metadata; Codec.validate_encoding! then hashes the base
      # once against that value and independently verifies the patched result.
      unless previous.request_hash == step.request_base_hash,
        do: raise(Error, reason: :hash_mismatch, step_id: previous.id)

      {previous, known_base}
    else
      validated_base!(step, actor, nil)
    end
  end

  defp validated_base!(step, actor, _known_base) do
    rows = window!(step.chat_message_id, step.sequence, actor)
    previous = Enum.find(rows, &(&1.sequence == step.sequence - 1))
    unless previous, do: raise(Error, reason: :missing_base)
    {previous, Reader.decode_snapshots!(rows, [previous.id]) |> Map.fetch!(previous.id)}
  end

  @doc "Independently proves that a physical rewrite cannot change any logical request."
  def validate_rewrite!(step_id, encoding, actor) do
    _actor = Reader.actor!(actor: actor)
    require_transaction!()
    attrs = rewrite_attributes!(encoding)

    initial =
      ChatMessageStep
      |> Ash.Query.filter(id == ^step_id)
      |> Ash.Query.select([:id, :chat_message_id, :sequence])
      |> Ash.read_one!(actor: actor, authorize?: true)

    unless initial, do: raise(Error, reason: :not_found, step_id: step_id)
    message = lock_message!(initial.chat_message_id, actor)
    require_terminal!(message)
    rows = window!(message.id, initial.sequence, actor)
    current = Enum.find(rows, &(&1.id == step_id))
    unless current, do: raise(Error, reason: :not_found, step_id: step_id)
    unless current.status in @terminal_statuses, do: raise(Error, reason: :active_message)

    successor = Enum.find(rows, &(&1.sequence == current.sequence + 1))
    previous = Enum.find(rows, &(&1.sequence == current.sequence - 1))
    candidate = Map.merge(current, attrs)

    ids =
      [
        current,
        if(candidate.request_mode == :patch, do: previous),
        if(match?(%{request_mode: :patch}, successor), do: successor)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)

    originals = Reader.decode_snapshots!(rows, ids)
    original = Map.fetch!(originals, step_id)

    {attrs, reconstructed} =
      Codec.validate_encoding_snapshot!(candidate, fn _attrs ->
        unless previous, do: raise(Error, reason: :missing_base)
        {previous, Map.fetch!(originals, previous.id)}
      end)

    unless reconstructed.hash == original.hash,
      do: raise(Error, reason: :logical_request_changed, step_id: step_id)

    # A checkpoint cannot be removed underneath an existing patch chain unless
    # its distance remains valid. Subsequent hashes refer to unchanged content.
    if match?(%{request_mode: :patch}, successor) do
      old_next = Map.fetch!(originals, successor.id)
      new_next = Codec.decode_snapshot!(successor, candidate, reconstructed)
      unless new_next.hash == old_next.hash, do: raise(Error, reason: :logical_request_changed)
    end

    {attrs, current.updated_at}
  end

  defp rewrite_attributes!(encoding) when is_map(encoding) and not is_struct(encoding) do
    expected = Enum.map(Codec.fields(), &Atom.to_string/1) |> MapSet.new()
    keys = Enum.map(Map.keys(encoding), &to_string/1)

    unless MapSet.new(keys) == expected and length(keys) == MapSet.size(expected),
      do: raise(Error, reason: :invalid_rewrite_fields)

    Map.new(Codec.fields(), fn field ->
      value =
        case Map.fetch(encoding, field) do
          {:ok, value} -> value
          :error -> Map.fetch!(encoding, Atom.to_string(field))
        end

      value =
        case {field, value} do
          {:request_mode, "full"} -> :full
          {:request_mode, "patch"} -> :patch
          _other -> value
        end

      {field, value}
    end)
  end

  defp rewrite_attributes!(_encoding), do: raise(Error, reason: :invalid_rewrite_fields)

  def lock_message!(message_id, actor, lock_chat? \\ true) do
    require_transaction!()

    query =
      ChatMessage
      |> Ash.Query.filter(id == ^message_id)
      |> Ash.Query.select(@message_fields)

    initial = Ash.read_one!(query, actor: actor, authorize?: true)
    unless initial && initial.owner_id == actor.id, do: raise(Error, reason: :not_found)

    if lock_chat? do
      chat =
        Chat
        |> Ash.Query.filter(id == ^initial.chat_id)
        |> Ash.Query.select([:id])
        |> Ash.Query.lock("FOR NO KEY UPDATE")
        |> Ash.read_one!(actor: actor, authorize?: true)

      unless chat, do: raise(Error, reason: :not_found)
    end

    current =
      query |> Ash.Query.lock(:for_update) |> Ash.read_one!(actor: actor, authorize?: true)

    unless current && current.owner_id == actor.id, do: raise(Error, reason: :not_found)
    current
  end

  def require_terminal!(message) do
    unless message.role == :assistant and message.status in @terminal_statuses,
      do: raise(Error, reason: :active_or_unsafe_message)
  end

  def terminal_steps?(steps), do: Enum.all?(steps, &(&1.status in @terminal_statuses))

  def window!(message_id, sequence, actor) do
    first = max(1, sequence - Codec.max_chain())
    last = sequence + 1

    ChatMessageStep
    |> Ash.Query.filter(
      chat_message_id == ^message_id and sequence >= ^first and sequence <= ^last
    )
    |> Ash.Query.select(Reader.fields())
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(actor: actor, authorize?: true)
  end

  def require_transaction! do
    unless Ash.DataLayer.in_transaction?(ChatMessageStep),
      do: raise(Error, reason: :transaction_required)
  end
end
