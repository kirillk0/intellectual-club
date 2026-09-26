defmodule IntellectualClub.Generation.StepRequests.Backfill do
  @moduledoc """
  Manual, bounded physical re-encoding. No startup or migration invokes this module.

  Each message is an independent transaction protected by a generation reservation
  and chat/message/step row locks. A batch scans at most the explicit message limit.
  Neither progress nor results contain logical requests or physical payloads.
  """

  alias IntellectualClub.Chat.{ChatMessage, ChatMessageStep}
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.StepRequests.{Codec, Error, Reader, Storage}

  require Ash.Query

  def run_batch(opts) do
    state = prepare!(opts)
    state = Enum.reduce(state.pending_ids, state, fn _id, state -> advance(state) end)
    {:ok, finish(state).summary}
  rescue
    error in [Error, ArgumentError] -> {:error, error}
  end

  @doc false
  def options!(opts) do
    opts =
      Keyword.validate!(opts, [
        :actor,
        :message_limit,
        after_id: 0,
        dry_run: true,
        max_steps_per_message: 256,
        max_chain: 32
      ])

    _actor = Reader.actor!(opts)
    bounded_integer!(Keyword.get(opts, :message_limit), 1, 100, :message_limit_required)
    bounded_integer!(opts[:max_steps_per_message], 1, 1_000, :invalid_step_limit)

    unless is_integer(opts[:after_id]) and opts[:after_id] >= 0,
      do: raise(Error, reason: :invalid_cursor)

    unless is_boolean(opts[:dry_run]), do: raise(Error, reason: :invalid_dry_run)
    _limit = Codec.chain_limit!(opts)
    opts
  end

  @doc false
  def prepare!(opts) do
    opts = options!(opts)
    actor = Reader.actor!(opts)
    after_id = opts[:after_id]
    message_limit = opts[:message_limit]

    candidates =
      ChatMessage
      |> Ash.Query.filter(owner_id == ^actor.id and role == :assistant and id > ^after_id)
      |> Ash.Query.select([:id])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(message_limit + 1)
      |> Ash.read!(actor: actor, authorize?: true)

    ids = candidates |> Enum.take(message_limit) |> Enum.map(& &1.id)

    %{
      actor: actor,
      opts: opts,
      pending_ids: ids,
      summary: %{
        status: :running,
        dry_run: opts[:dry_run],
        after_id: after_id,
        next_cursor: after_id,
        message_limit: message_limit,
        selected_messages: length(ids),
        scanned_messages: 0,
        rewritten_messages: 0,
        rewritten_steps: 0,
        would_rewrite_messages: 0,
        would_rewrite_steps: 0,
        unchanged_messages: 0,
        skipped_messages: 0,
        skips: [],
        has_more: length(candidates) > message_limit
      }
    }
  end

  @doc false
  def advance(%{pending_ids: [id | rest]} = state) do
    result = process_message(id, state.actor, state.opts)

    summary =
      state.summary |> Map.update!(:scanned_messages, &(&1 + 1)) |> Map.put(:next_cursor, id)

    dry_run? = state.opts[:dry_run]

    summary =
      case result do
        {:ok, 0} ->
          Map.update!(summary, :unchanged_messages, &(&1 + 1))

        {:ok, count} when dry_run? ->
          summary
          |> Map.update!(:would_rewrite_messages, &(&1 + 1))
          |> Map.update!(:would_rewrite_steps, &(&1 + count))

        {:ok, count} ->
          summary
          |> Map.update!(:rewritten_messages, &(&1 + 1))
          |> Map.update!(:rewritten_steps, &(&1 + count))

        {:skip, reason} ->
          summary
          |> Map.update!(:skipped_messages, &(&1 + 1))
          |> Map.update!(:skips, &(&1 ++ [%{message_id: id, reason: reason}]))
      end

    %{state | pending_ids: rest, summary: summary}
  end

  def advance(state), do: state

  @doc false
  def finish(state), do: put_in(state.summary.status, :done)

  defp process_message(id, actor, opts) do
    # reserve/1 takes the existing cross-node generation exclusion without
    # creating/changing a generation fence token or logical message state.
    case Lease.reserve(id) do
      {:ok, lease} ->
        try do
          case Ash.transaction([ChatMessage, ChatMessageStep], fn ->
                 rewrite_message!(id, actor, opts)
               end) do
            {:ok, count} -> {:ok, count}
            {:error, _error} -> {:skip, :storage_error}
          end
        after
          Lease.release(lease)
        end

      {:error, :already_running} ->
        {:skip, :active_generation}

      {:error, _error} ->
        {:skip, :generation_reservation_unavailable}
    end
  rescue
    error in Error -> {:skip, error.reason}
    _error -> {:skip, :storage_error}
  end

  defp rewrite_message!(id, actor, opts) do
    message = Storage.lock_message!(id, actor)
    Storage.require_terminal!(message)
    limit = opts[:max_steps_per_message]

    metadata =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^id)
      |> Ash.Query.select([:id, :sequence, :status, :owner_id])
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.Query.limit(limit + 1)
      |> Ash.Query.lock(:for_update)
      |> Ash.read!(actor: actor, authorize?: true)

    cond do
      metadata == [] ->
        raise Error, reason: :no_steps

      length(metadata) > limit ->
        raise Error, reason: :step_limit_exceeded

      not Storage.terminal_steps?(metadata) ->
        raise Error, reason: :active_steps

      not Enum.all?(metadata, &(&1.owner_id == actor.id)) ->
        raise Error, reason: :unsafe_step_owner

      not contiguous?(metadata) ->
        raise Error, reason: :sequence_gap

      true ->
        :ok
    end

    ids = Enum.map(metadata, & &1.id)

    steps =
      ChatMessageStep
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select(Reader.fields())
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.read!(actor: actor, authorize?: true)

    before = Reader.decode_rows!(steps)
    planned = plan(steps, before, opts)

    unless Reader.decode_rows!(planned) === before,
      do: raise(Error, reason: :logical_request_changed)

    changes =
      Enum.zip(steps, planned)
      |> Enum.reject(fn {old, new} ->
        Map.take(old, Codec.fields()) === Map.take(new, Codec.fields())
      end)

    unless opts[:dry_run] do
      Enum.each(changes, fn {old, new} ->
        old
        |> Ash.Changeset.for_update(
          :rewrite_request_encoding,
          %{},
          actor: actor,
          private_arguments: %{encoding: Map.take(new, Codec.fields())}
        )
        |> Ash.update!(actor: actor, authorize?: true)
      end)

      after_rows =
        ChatMessageStep
        |> Ash.Query.filter(chat_message_id == ^id)
        |> Ash.Query.select(Reader.fields())
        |> Ash.Query.sort(sequence: :asc)
        |> Ash.read!(actor: actor, authorize?: true)

      unless Reader.decode_rows!(after_rows) === before,
        do: raise(Error, reason: :logical_request_changed)
    end

    length(changes)
  end

  defp plan(steps, requests, opts) do
    following = tl(steps) ++ [nil]

    {planned, _previous} =
      Enum.zip(steps, following)
      |> Enum.map_reduce(nil, fn {step, successor}, previous ->
        request = Map.fetch!(requests, step.id)

        attrs =
          if step.request_mode == :patch do
            # Keep existing verified patches. In particular, retain the full
            # checkpoint immediately before an existing patch chain.
            Map.take(step, Codec.fields())
          else
            Codec.create_attributes(request,
              sequence: step.sequence,
              previous_step: previous,
              previous_request: if(previous, do: Map.fetch!(requests, previous.id)),
              force_full: not is_nil(successor) and successor.request_mode == :patch,
              max_chain: opts[:max_chain]
            )
          end

        current = Map.merge(step, attrs)
        {current, current}
      end)

    planned
  end

  defp contiguous?(steps),
    do: steps |> Enum.with_index(1) |> Enum.all?(fn {step, index} -> step.sequence == index end)

  defp bounded_integer!(value, first, last, reason) do
    unless is_integer(value) and value >= first and value <= last,
      do: raise(Error, reason: reason)
  end
end
