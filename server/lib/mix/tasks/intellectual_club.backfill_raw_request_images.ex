defmodule Mix.Tasks.IntellectualClub.BackfillRawRequestImages do
  @shortdoc "Compacts legacy raw request images into step-owned files"

  @moduledoc """
  Compacts legacy embedded images in `chat_message_steps.raw_request`.

  The task defaults to a read-only dry run. Use `--apply` explicitly to write changes.

      mix intellectual_club.backfill_raw_request_images --dry-run
      mix intellectual_club.backfill_raw_request_images --apply --sleep-ms 25
      mix intellectual_club.backfill_raw_request_images --apply --after-id 10000
      mix intellectual_club.backfill_raw_request_images --apply --allow-errors

  The runner uses keyset pagination and one short transaction per affected terminal step.
  `--through-id` is fixed to the current maximum step ID when omitted, so requests created while
  the task is running are never included in that run.
  """

  use Mix.Task

  alias IntellectualClub.Generation.LegacyRequestImages.Backfill

  @switches [
    apply: :boolean,
    dry_run: :boolean,
    after_id: :integer,
    through_id: :integer,
    id_page_size: :integer,
    sleep_ms: :integer,
    max_steps: :integer,
    progress_every: :integer,
    halt_on_error: :boolean,
    allow_errors: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(positional ++ invalid)}")
    end

    dry_run? = mode!(parsed)

    opts = [
      dry_run?: dry_run?,
      after_id: Keyword.get(parsed, :after_id, 0),
      through_id: Keyword.get(parsed, :through_id),
      page_size: Keyword.get(parsed, :id_page_size, 200),
      sleep_ms: Keyword.get(parsed, :sleep_ms, 0),
      max_steps: Keyword.get(parsed, :max_steps),
      progress_every: Keyword.get(parsed, :progress_every, 250),
      halt_on_error?: Keyword.get(parsed, :halt_on_error, false),
      progress: &print_progress/1
    ]

    case Backfill.run(opts) do
      {:ok, stats} ->
        Mix.shell().info("BACKFILL_SUMMARY #{Jason.encode!(stats)}")

        if stats.unresolved_count > 0 and not Keyword.get(parsed, :allow_errors, false) do
          Mix.raise(
            "Backfill has #{stats.unresolved_count} unresolved steps " <>
              "(#{stats.failed} failed, #{stats.active_skipped} active). " <>
              resume_message(stats)
          )
        end

        if not stats.scan_complete do
          Mix.shell().info("BACKFILL_INCOMPLETE #{resume_message(stats)}")
        end

        :ok

      {:error, {reason, stats}} when is_map(stats) ->
        Mix.shell().error("BACKFILL_SUMMARY #{Jason.encode!(stats)}")
        Mix.raise("Backfill stopped: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("Backfill failed: #{inspect(reason)}")
    end
  end

  defp mode!(parsed) do
    apply? = Keyword.get(parsed, :apply, false)
    dry_run? = Keyword.get(parsed, :dry_run, false)

    cond do
      apply? and dry_run? -> Mix.raise("Choose either --apply or --dry-run, not both.")
      apply? -> false
      true -> true
    end
  end

  defp print_progress(stats) do
    Mix.shell().info("BACKFILL_PROGRESS #{Jason.encode!(stats)}")
  end

  defp resume_message(stats) do
    "Successful steps were preserved. Resume with --after-id #{stats.resume_after_id} " <>
      "--through-id #{stats.through_id}."
  end
end
