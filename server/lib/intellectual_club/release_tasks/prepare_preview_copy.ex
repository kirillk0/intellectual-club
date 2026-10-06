defmodule IntellectualClub.ReleaseTasks.PreparePreviewCopy do
  @moduledoc """
  Release task that makes a copy of a live database safe for a preview instance.

  A preview (for example, a pull request environment) boots from a copy of the
  main database. Without preparation its startup recovery would resume the
  copied in-flight work and repeat real side effects on behalf of the main
  instance: LLM requests, background fork/spawn restarts, Web Push deliveries
  to real devices, and rotation of OpenAI OAuth refresh tokens that the main
  instance still uses.

  The task runs pending migrations and then, in one transaction, neutralizes
  that state without contacting any external system:

    * generating assistant messages fail, so orphaned-generation recovery has
      nothing to resume;
    * pending queued messages are paused with the `"preview_copy"` reason, so
      the queue dispatcher never starts a new turn on its own;
    * non-terminal background tasks fail without asking their runners to stop
      (the runners belong to the main instance);
    * Web Push subscriptions are deleted and undelivered generation events are
      acknowledged, so the preview never notifies real devices;
    * stored OAuth refresh tokens are cleared, so the preview never rotates a
      token the main instance depends on. Providers stay configured and can be
      re-authenticated in the preview.

  Run it from a one-off release container before the preview app starts:

      bin/intellectual_club eval "IntellectualClub.ReleaseTasks.PreparePreviewCopy.main()"

  The task is idempotent. It exits with a non-zero status when it fails.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.QueuedMessage
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Notifications.WebPushGenerationEvent
  alias IntellectualClub.Notifications.WebPushSubscription
  alias IntellectualClub.Repo

  require Ash.Query

  @queue_block_reason "preview_copy"
  @generation_error_detail "The generation was interrupted because this database was copied for a preview instance."
  @background_task_error_code "preview_copy"
  @background_task_error_message "The background task was interrupted because this database was copied for a preview instance."
  @terminal_background_task_statuses [:completed, :failed, :canceled]
  @transaction_resources [
    ChatMessage,
    ChatMessageStep,
    QueuedMessage,
    BackgroundTask,
    WebPushSubscription,
    WebPushGenerationEvent,
    LlmProvider
  ]

  @type summary :: %{
          generations_failed: non_neg_integer(),
          queued_messages_paused: non_neg_integer(),
          background_tasks_failed: non_neg_integer(),
          web_push_subscriptions_deleted: non_neg_integer(),
          web_push_events_acknowledged: non_neg_integer(),
          oauth_refresh_tokens_cleared: non_neg_integer()
        }

  @doc """
  Migrates and prepares the configured database, printing a summary.

  Terminates the VM with a non-zero status on failure.
  """
  @spec main() :: :ok | no_return()
  def main do
    case run_with_migrations() do
      {:ok, summary} ->
        print_summary(summary)
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Failed to prepare the preview database copy: #{format_error(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Neutralizes copied state in the current database without running migrations.

  Every change happens in one transaction: either the whole copy is prepared or
  nothing changes.
  """
  @spec run() :: {:ok, summary()} | {:error, term()}
  def run do
    Ash.transaction(@transaction_resources, &prepare!/0)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_with_migrations do
    case Ecto.Migrator.with_repo(Repo, fn repo ->
           Ecto.Migrator.run(repo, :up, all: true)
           run()
         end) do
      {:ok, result, _started_apps} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare! do
    generations_failed = fail_generations!()
    queued_messages_paused = pause_pending_queue!()
    background_tasks_failed = fail_background_tasks!()
    web_push_subscriptions_deleted = delete_web_push_subscriptions!()
    web_push_events_acknowledged = acknowledge_web_push_events!()
    oauth_refresh_tokens_cleared = clear_oauth_refresh_tokens!()

    %{
      generations_failed: generations_failed,
      queued_messages_paused: queued_messages_paused,
      background_tasks_failed: background_tasks_failed,
      web_push_subscriptions_deleted: web_push_subscriptions_deleted,
      web_push_events_acknowledged: web_push_events_acknowledged,
      oauth_refresh_tokens_cleared: oauth_refresh_tokens_cleared
    }
  end

  # Uses the same selection as orphaned-generation recovery, so everything it
  # would resume at startup is failed here instead.
  defp fail_generations! do
    Persistence.list_generating_messages_for_resume!()
    |> Enum.sort_by(& &1.id)
    |> Enum.count(fn %{id: message_id} ->
      Persistence.fail_generating_message!(message_id, error_detail: @generation_error_detail) ==
        :failed
    end)
  end

  # Pending entries are what the queue dispatcher delivers at startup. The
  # `preview_copy` reason is not a terminal-generation reason, so a later queue
  # settlement never resumes these entries without an explicit user action.
  # Pending steering becomes a paused follow-up, as it does when its target
  # generation ends.
  defp pause_pending_queue! do
    QueuedMessage
    |> Ash.Query.filter(status == :pending)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&pause_queued_message!/1)
    |> length()
  end

  defp pause_queued_message!(%QueuedMessage{kind: :steer} = queued_message) do
    update_queued_message!(queued_message, %{
      kind: :follow_up,
      status: :blocked,
      blocked_reason: @queue_block_reason,
      anchor_message_id: queued_message.target_generation_message_id,
      target_generation_message_id: nil,
      finished_at: nil
    })
  end

  defp pause_queued_message!(%QueuedMessage{} = queued_message) do
    update_queued_message!(queued_message, %{
      status: :blocked,
      blocked_reason: @queue_block_reason,
      finished_at: nil
    })
  end

  defp update_queued_message!(%QueuedMessage{} = queued_message, attrs) do
    actor = owner(queued_message.owner_id)

    queued_message
    |> Ash.Changeset.for_update(:update_state, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  # Marks tasks failed directly: cancellation would ask SSH hosts and outlets
  # to stop processes that still belong to the main instance.
  defp fail_background_tasks! do
    BackgroundTask
    |> Ash.Query.filter(status not in ^@terminal_background_task_statuses)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.count(fn task ->
      case BackgroundTasks.mark_failed(
             task,
             @background_task_error_code,
             @background_task_error_message,
             "unknown"
           ) do
        {:ok, %BackgroundTask{status: :failed}} ->
          true

        {:ok, %BackgroundTask{}} ->
          false

        {:error, reason} ->
          raise "Failed to fail background task #{task.id}: #{inspect(reason)}"
      end
    end)
  end

  defp delete_web_push_subscriptions! do
    WebPushSubscription
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn subscription ->
      Ash.destroy!(subscription, actor: owner(subscription.owner_id))
    end)
    |> length()
  end

  # Without subscriptions these events cannot reach a device; acknowledging
  # them keeps the startup delivery recovery from replaying them to devices
  # subscribed in the preview later.
  defp acknowledge_web_push_events! do
    WebPushGenerationEvent
    |> Ash.Query.filter(suppressed == false and delivered_count < 0)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn event ->
      actor = owner(event.owner_id)

      event
      |> Ash.Changeset.for_update(:mark_delivered, %{delivered_count: 0}, actor: actor)
      |> Ash.update!(actor: actor)
    end)
    |> length()
  end

  defp clear_oauth_refresh_tokens! do
    LlmProvider
    |> Ash.Query.filter(not is_nil(oauth_refresh_token))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn provider ->
      actor = owner(provider.owner_id)

      provider
      |> Ash.Changeset.for_update(:clear_oauth_refresh_token, %{}, actor: actor)
      |> Ash.update!(actor: actor)
    end)
    |> length()
  end

  defp owner(owner_id) when is_integer(owner_id), do: %User{id: owner_id}

  defp print_summary(summary) do
    IO.puts("""
    Preview database copy prepared:
      generations failed: #{summary.generations_failed}
      queued messages paused: #{summary.queued_messages_paused}
      background tasks failed: #{summary.background_tasks_failed}
      web push subscriptions deleted: #{summary.web_push_subscriptions_deleted}
      web push events acknowledged: #{summary.web_push_events_acknowledged}
      oauth refresh tokens cleared: #{summary.oauth_refresh_tokens_cleared}\
    """)
  end

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end
