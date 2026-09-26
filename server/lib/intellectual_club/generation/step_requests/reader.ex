defmodule IntellectualClub.Generation.StepRequests.Reader do
  @moduledoc false

  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Generation.StepRequests.{Codec, Error}

  require Ash.Query

  @batch_size 100
  @metadata_fields [:id, :chat_message_id, :sequence]

  def fields, do: @metadata_fields ++ [:owner_id, :status, :updated_at] ++ Codec.fields()

  def actor!(opts) do
    case Keyword.get(opts, :actor) do
      %{id: id} = actor when is_integer(id) and id > 0 -> actor
      _other -> raise Error, reason: :actor_required
    end
  end

  def requests_for_steps!(steps, opts) when is_list(steps) do
    actor = actor!(opts)
    ids = steps |> Enum.map(&step_id!/1) |> Enum.uniq()

    # Always re-read: projected records may have nil for an unselected raw map,
    # and accepting a caller's preloaded payload would bypass authorization.
    metadata =
      ids
      |> Enum.chunk_every(@batch_size)
      |> Enum.flat_map(fn batch ->
        ChatMessageStep
        |> Ash.Query.filter(id in ^batch)
        |> Ash.Query.select(@metadata_fields)
        |> Ash.read!(actor: actor, authorize?: true)
      end)

    require_ids!(metadata, ids)

    rows =
      metadata
      |> windows()
      |> Enum.chunk_every(@batch_size)
      |> Enum.flat_map(fn windows ->
        filter = [or: Enum.map(windows, &window_filter/1)]

        ChatMessageStep
        |> Ash.Query.filter(^filter)
        |> Ash.Query.select(fields())
        |> Ash.read!(actor: actor, authorize?: true)
      end)
      |> Enum.uniq_by(& &1.id)

    require_ids!(rows, ids)
    decode_rows!(rows, ids)
  end

  @doc false
  def decode_rows!(rows, ids \\ nil) do
    by_key = Map.new(rows, &{{&1.chat_message_id, &1.sequence}, &1})
    by_id = Map.new(rows, &{&1.id, &1})
    ids = ids || Enum.map(rows, & &1.id)

    if map_size(by_key) != length(rows), do: raise(Error, reason: :duplicate_sequence)

    {_cache, result} =
      Enum.reduce(ids, {%{}, %{}}, fn id, {cache, result} ->
        step = Map.get(by_id, id) || raise(Error, reason: :not_found, step_id: id)
        {request, cache} = resolve!(step, by_key, cache, 0)
        {cache, Map.put(result, id, request)}
      end)

    result
  end

  defp resolve!(step, by_key, cache, depth) do
    if depth > Codec.max_chain(), do: raise(Error, reason: :chain_too_long, step_id: step.id)

    case Map.fetch(cache, step.id) do
      {:ok, request} ->
        {request, cache}

      :error ->
        {request, cache} =
          if step.request_mode == :patch do
            previous = Map.get(by_key, {step.chat_message_id, step.sequence - 1})
            unless previous, do: raise(Error, reason: :missing_base, step_id: step.id)
            {base, cache} = resolve!(previous, by_key, cache, depth + 1)
            {Codec.decode!(step, previous, base), cache}
          else
            {Codec.decode!(step), cache}
          end

        {request, Map.put(cache, step.id, request)}
    end
  end

  defp windows(metadata) do
    metadata
    |> Enum.group_by(& &1.chat_message_id)
    |> Enum.flat_map(fn {message_id, rows} ->
      rows
      |> Enum.map(&{max(1, &1.sequence - Codec.max_chain()), &1.sequence})
      |> Enum.sort()
      |> Enum.reduce([], fn
        {first, last}, [{start, finish} | rest] when first <= finish + 1 ->
          [{start, max(last, finish)} | rest]

        range, ranges ->
          [range | ranges]
      end)
      |> Enum.map(fn {first, last} -> {message_id, first, last} end)
    end)
  end

  defp window_filter({message_id, first, last}) do
    [
      chat_message_id: message_id,
      sequence: [greater_than_or_equal: first, less_than_or_equal: last]
    ]
  end

  defp require_ids!(rows, ids) do
    found = MapSet.new(rows, & &1.id)

    Enum.each(ids, fn id ->
      unless MapSet.member?(found, id), do: raise(Error, reason: :not_found, step_id: id)
    end)
  end

  defp step_id!(%{id: id}), do: step_id!(id)
  defp step_id!(id) when is_integer(id) and id > 0, do: id
  defp step_id!(_step), do: raise(Error, reason: :invalid_step_id)
end
