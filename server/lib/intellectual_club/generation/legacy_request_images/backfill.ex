defmodule IntellectualClub.Generation.LegacyRequestImages.Backfill do
  @moduledoc """
  Sequential, resumable runner for compacting legacy raw request images.

  ID pages contain only identifiers and statuses. Each terminal step is loaded separately and,
  when affected, migrated in its own transaction. A session advisory lock prevents concurrent
  runners from staging files for the same database.
  """

  require Ash.Query

  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Generation.LegacyRequestImages
  alias IntellectualClub.Repo

  @advisory_lock_key 4_962_434_762_617
  @default_page_size 200
  @default_progress_every 250
  @max_recorded_errors 100
  @terminal_statuses [:done, :error, :canceled]

  @type stats :: map()

  @spec run(keyword()) :: {:ok, stats()} | {:error, term()}
  def run(opts \\ [])

  def run(opts) when is_list(opts) do
    with {:ok, normalized_opts} <- normalize_options(opts) do
      Repo.checkout(
        fn -> with_advisory_lock(fn -> run_locked(normalized_opts) end) end,
        timeout: :infinity
      )
    end
  rescue
    error -> {:error, {:legacy_request_image_backfill_crashed, Exception.message(error)}}
  catch
    kind, value -> {:error, {:legacy_request_image_backfill_crashed, {kind, value}}}
  end

  def run(_opts), do: {:error, :invalid_options}

  defp normalize_options(opts) do
    normalized = %{
      dry_run?: Keyword.get(opts, :dry_run?, true),
      after_id: Keyword.get(opts, :after_id, 0),
      through_id: Keyword.get(opts, :through_id),
      page_size: Keyword.get(opts, :page_size, @default_page_size),
      sleep_ms: Keyword.get(opts, :sleep_ms, 0),
      max_steps: Keyword.get(opts, :max_steps),
      progress_every: Keyword.get(opts, :progress_every, @default_progress_every),
      halt_on_error?: Keyword.get(opts, :halt_on_error?, false),
      progress: Keyword.get(opts, :progress, fn _stats -> :ok end)
    }

    cond do
      not is_boolean(normalized.dry_run?) -> {:error, :invalid_dry_run}
      not non_negative_integer?(normalized.after_id) -> {:error, :invalid_after_id}
      not optional_non_negative_integer?(normalized.through_id) -> {:error, :invalid_through_id}
      not positive_integer?(normalized.page_size) -> {:error, :invalid_page_size}
      not non_negative_integer?(normalized.sleep_ms) -> {:error, :invalid_sleep_ms}
      not optional_positive_integer?(normalized.max_steps) -> {:error, :invalid_max_steps}
      not positive_integer?(normalized.progress_every) -> {:error, :invalid_progress_every}
      not is_boolean(normalized.halt_on_error?) -> {:error, :invalid_halt_on_error}
      not is_function(normalized.progress, 1) -> {:error, :invalid_progress_callback}
      true -> {:ok, normalized}
    end
  end

  defp with_advisory_lock(fun) do
    case advisory_lock_query("SELECT pg_try_advisory_lock($1)") do
      {:ok, %{rows: [[true]]}} ->
        try do
          fun.()
        after
          release_advisory_lock!()
        end

      {:ok, %{rows: [[false]]}} ->
        {:error, :legacy_request_image_backfill_already_running}

      failure ->
        # The connection may have acquired the session lock before an ambiguous query failure.
        Repo.disconnect_all(0)
        {:error, {:legacy_request_image_backfill_lock_failed, failure}}
    end
  end

  defp release_advisory_lock! do
    unlock_result = advisory_lock_query("SELECT pg_advisory_unlock($1)")

    case unlock_result do
      {:ok, %{rows: [[true]]}} ->
        :ok

      failure ->
        # A failed unlock may leave the session-level lock attached to this connection. Mark all
        # pooled connections for recycling so the checked-out session cannot return to the pool.
        Repo.disconnect_all(0)
        raise "legacy request image backfill advisory unlock failed: #{inspect(failure)}"
    end
  end

  defp advisory_lock_query(statement) do
    try do
      Repo.query(statement, [@advisory_lock_key])
    rescue
      error -> {:raised, error}
    catch
      kind, value -> {:caught, kind, value}
    end
  end

  defp run_locked(opts) do
    with {:ok, recovered_staged_files} <- maybe_cleanup_staged_files(opts),
         {:ok, through_id} <- resolve_through_id(opts.through_id) do
      started_at = System.monotonic_time(:millisecond)

      stats = %{
        mode: if(opts.dry_run?, do: :dry_run, else: :apply),
        after_id: opts.after_id,
        through_id: through_id,
        scan_cursor: opts.after_id,
        scan_complete?: false,
        scanned: 0,
        active_skipped: 0,
        noops: 0,
        candidates: 0,
        migrated: 0,
        failed: 0,
        occurrences: 0,
        bindings: 0,
        identity_bindings: 0,
        thumbnail_bindings: 0,
        legacy_exact_bindings: 0,
        missing_sources: 0,
        wire_changed_oversized: 0,
        encoded_chars: 0,
        decoded_bytes: 0,
        legacy_json_bytes: 0,
        compact_json_bytes: 0,
        unique_payloads: 0,
        unique_payload_bytes: 0,
        cleanup_errors: 0,
        recovered_staged_files: recovered_staged_files,
        errors: [],
        unresolved_step_ids: [],
        seen_payload_shas: MapSet.new(),
        started_at_ms: started_at
      }

      case process_pages(stats, opts) do
        {:ok, final_stats} -> {:ok, finalize_stats(final_stats)}
        {:error, reason, final_stats} -> {:error, {reason, finalize_stats(final_stats)}}
      end
    end
  end

  defp maybe_cleanup_staged_files(%{dry_run?: true}), do: {:ok, 0}

  defp maybe_cleanup_staged_files(%{dry_run?: false}) do
    case LegacyRequestImages.cleanup_unbound_staged_files() do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, {:cleanup_unbound_legacy_request_image_files_failed, reason}}
    end
  end

  defp process_pages(stats, opts) do
    cond do
      stats.scan_cursor >= stats.through_id ->
        {:ok, %{stats | scan_complete?: true}}

      max_steps_reached?(stats, opts.max_steps) ->
        {:ok, stats}

      true ->
        page_limit = page_limit(stats, opts)

        case load_id_page(stats.scan_cursor, stats.through_id, page_limit) do
          {:ok, []} ->
            {:ok, %{stats | scan_complete?: true}}

          {:ok, steps} ->
            case process_page(steps, stats, opts) do
              {:ok, next_stats} -> process_pages(next_stats, opts)
              {:error, reason, next_stats} -> {:error, reason, next_stats}
            end

          {:error, reason} ->
            {:error, {:load_legacy_request_image_id_page_failed, reason}, stats}
        end
    end
  end

  defp process_page(steps, stats, opts) do
    Enum.reduce_while(steps, {:ok, stats}, fn step, {:ok, current_stats} ->
      next_stats = %{
        current_stats
        | scanned: current_stats.scanned + 1,
          scan_cursor: step.id
      }

      result =
        if step.status in @terminal_statuses do
          LegacyRequestImages.migrate_step(step.id, dry_run?: opts.dry_run?)
        else
          {:ok, %{status: :active, step_id: step.id}}
        end

      case result do
        {:ok, migration_result} ->
          updated_stats = merge_result(next_stats, migration_result)
          maybe_progress(updated_stats, opts)
          maybe_sleep(migration_result.status, opts.sleep_ms)
          {:cont, {:ok, updated_stats}}

        {:error, reason} ->
          updated_stats = record_error(next_stats, step.id, reason)
          maybe_progress(updated_stats, opts, true)

          if opts.halt_on_error? do
            {:halt, {:error, {:legacy_request_image_step_failed, step.id, reason}, updated_stats}}
          else
            {:cont, {:ok, updated_stats}}
          end
      end
    end)
  end

  defp merge_result(stats, %{status: :active, step_id: step_id}) do
    %{
      stats
      | active_skipped: stats.active_skipped + 1,
        unresolved_step_ids: [step_id | stats.unresolved_step_ids]
    }
  end

  defp merge_result(stats, %{status: :noop}),
    do: %{stats | noops: stats.noops + 1}

  defp merge_result(stats, %{status: status} = result)
       when status in [:candidate, :migrated] do
    stats =
      stats
      |> Map.update!(status_counter(status), &(&1 + 1))
      |> Map.update!(:occurrences, &(&1 + result.occurrences))
      |> Map.update!(:bindings, &(&1 + result.bindings))
      |> Map.update!(:identity_bindings, &(&1 + result.identity_bindings))
      |> Map.update!(:thumbnail_bindings, &(&1 + result.thumbnail_bindings))
      |> Map.update!(:legacy_exact_bindings, &(&1 + result.legacy_exact_bindings))
      |> Map.update!(:missing_sources, &(&1 + result.missing_sources))
      |> Map.update!(:wire_changed_oversized, &(&1 + result.wire_changed_oversized))
      |> Map.update!(:encoded_chars, &(&1 + result.encoded_chars))
      |> Map.update!(:decoded_bytes, &(&1 + result.decoded_bytes))
      |> Map.update!(:legacy_json_bytes, &(&1 + result.legacy_json_bytes))
      |> Map.update!(:compact_json_bytes, &(&1 + result.compact_json_bytes))
      |> Map.update!(:cleanup_errors, &(&1 + length(result.cleanup_errors)))

    Enum.reduce(result.payloads, stats, &merge_payload/2)
  end

  defp merge_payload(payload, stats) do
    if MapSet.member?(stats.seen_payload_shas, payload.sha256) do
      stats
    else
      %{
        stats
        | seen_payload_shas: MapSet.put(stats.seen_payload_shas, payload.sha256),
          unique_payloads: stats.unique_payloads + 1,
          unique_payload_bytes: stats.unique_payload_bytes + payload.bytes
      }
    end
  end

  defp status_counter(:candidate), do: :candidates
  defp status_counter(:migrated), do: :migrated

  defp record_error(stats, step_id, reason) do
    errors =
      if length(stats.errors) < @max_recorded_errors do
        stats.errors ++
          [%{step_id: step_id, reason: inspect(reason, limit: 20, printable_limit: 500)}]
      else
        stats.errors
      end

    %{
      stats
      | failed: stats.failed + 1,
        errors: errors,
        unresolved_step_ids: [step_id | stats.unresolved_step_ids]
    }
  end

  defp maybe_progress(stats, opts, force? \\ false) do
    if force? or rem(stats.scanned, opts.progress_every) == 0 do
      opts.progress.(progress_snapshot(stats))
    end
  end

  defp progress_snapshot(stats) do
    unresolved_step_ids = Enum.sort(stats.unresolved_step_ids)

    stats
    |> Map.drop([
      :scan_cursor,
      :scan_complete?,
      :seen_payload_shas,
      :started_at_ms,
      :unresolved_step_ids
    ])
    |> Map.put(:scan_complete, stats.scan_complete?)
    |> Map.put(:scanned_through_id, stats.scan_cursor)
    |> Map.put(:resume_after_id, resume_after_id(stats, unresolved_step_ids))
    |> Map.put(:unresolved_count, length(unresolved_step_ids))
    |> Map.put(:unresolved_step_ids, unresolved_step_ids)
    |> Map.put(:elapsed_ms, elapsed_ms(stats))
  end

  defp finalize_stats(stats) do
    stats
    |> progress_snapshot()
    |> Map.put(:saved_json_bytes, max(stats.legacy_json_bytes - stats.compact_json_bytes, 0))
    |> Map.put(
      :complete,
      stats.scan_complete? and stats.unresolved_step_ids == []
    )
  end

  defp resume_after_id(_stats, [first_unresolved_id | _rest]),
    do: max(first_unresolved_id - 1, 0)

  defp resume_after_id(%{scan_complete?: true, through_id: through_id}, []), do: through_id
  defp resume_after_id(%{scan_cursor: scan_cursor}, []), do: scan_cursor

  defp elapsed_ms(stats), do: System.monotonic_time(:millisecond) - stats.started_at_ms

  defp maybe_sleep(status, sleep_ms)
       when status in [:candidate, :migrated] and sleep_ms > 0,
       do: Process.sleep(sleep_ms)

  defp maybe_sleep(_status, _sleep_ms), do: :ok

  defp resolve_through_id(value) when is_integer(value), do: {:ok, value}

  defp resolve_through_id(nil) do
    ChatMessageStep
    |> Ash.Query.sort(id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ChatMessageStep{id: id}} -> {:ok, id}
      {:ok, nil} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_id_page(after_id, through_id, limit) do
    ChatMessageStep
    |> Ash.Query.filter(id > ^after_id and id <= ^through_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.select([:id, :status])
    |> Ash.read(authorize?: false)
  end

  defp page_limit(stats, opts) do
    case opts.max_steps do
      nil -> opts.page_size
      max_steps -> min(opts.page_size, max_steps - stats.scanned)
    end
  end

  defp max_steps_reached?(_stats, nil), do: false
  defp max_steps_reached?(stats, max_steps), do: stats.scanned >= max_steps

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp optional_positive_integer?(nil), do: true
  defp optional_positive_integer?(value), do: positive_integer?(value)
  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: non_negative_integer?(value)
end
