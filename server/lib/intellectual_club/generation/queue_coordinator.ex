defmodule IntellectualClub.Generation.QueueCoordinator do
  @moduledoc """
  Coordinates durable chat turns against queued messages.

  Chat, assistant, and queue rows are locked in that order. The resulting
  assistant generation is fully persisted before a worker is started.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.QueuedMessage
  alias IntellectualClub.Chat.QueuedMessageContent
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Generation.Context.{PublicationError, StalePreparationError}
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Notifications
  alias IntellectualClub.Notifications.Dispatcher, as: NotificationsDispatcher
  alias IntellectualClub.Notifications.WebPushGenerationEvent

  require Ash.Query

  @active_queue_statuses [:pending, :blocked]
  @terminal_block_reasons ["generation_error", "generation_canceled"]
  @transaction_resources [
    Chat,
    ChatMessage,
    ChatMessageStep,
    ChatMessageItem,
    ChatMessageContent,
    QueuedMessage,
    QueuedMessageContent,
    BackgroundTask,
    WebPushGenerationEvent
  ]

  @type prepare_result ::
          {:ok, map()}
          | :empty
          | :active
          | {:blocked, atom() | String.t()}
          | {:error, term()}

  @doc "Prepares exactly one FIFO follow-up turn without starting its worker."
  @spec prepare_next(integer(), keyword()) :: prepare_result()
  def prepare_next(chat_id, opts \\ [])

  def prepare_next(chat_id, opts) when is_integer(chat_id) and is_list(opts) do
    boundary_message_id = Keyword.get(opts, :boundary_message_id)

    prepare_next_attempt(chat_id, boundary_message_id, 2)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def prepare_next(_chat_id, _opts), do: {:error, :invalid_chat_id}

  @doc "Prepares a direct request before publishing under the same locks as dequeue."
  @spec prepare_direct_generation(integer(), keyword(), nil | (-> term())) ::
          {:ok, map()} | {:error, term()}
  def prepare_direct_generation(chat_id, opts \\ [], prepare_parent \\ nil)

  def prepare_direct_generation(chat_id, opts, prepare_parent)
      when is_integer(chat_id) and is_list(opts) and
             (is_nil(prepare_parent) or is_function(prepare_parent, 0)) do
    if is_nil(prepare_parent) do
      prepare_direct_attempt(chat_id, opts, 2)
    else
      # Arbitrary callbacks may mutate the parent/history. Until they provide a
      # read-only intent, run both callback and request build under one boundary.
      prepare_direct_locked(chat_id, opts, prepare_parent, nil)
    end
  rescue
    error in PublicationError -> {:error, error.reason}
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def prepare_direct_generation(_chat_id, _opts, _prepare_parent),
    do: {:error, :invalid_chat_id}

  @doc "Applies a terminal generation boundary to its still-undelivered queue."
  @spec settle_generation(integer(), :done | :error | :canceled) ::
          {:ok, map()} | {:error, term()}
  def settle_generation(message_id, status)
      when is_integer(message_id) and status in [:done, :error, :canceled] do
    case message_chat_owner(message_id) do
      {:ok, %{chat_id: chat_id, owner_id: owner_id}} ->
        transact(fn ->
          _chat = lock_chat!(chat_id)
          message = lock_message!(message_id)

          cond do
            message.chat_id != chat_id ->
              {:error, :message_chat_changed}

            message.role != :assistant ->
              {:error, :assistant_only}

            message.status != status ->
              {:error, :stale_generation_boundary}

            true ->
              _ = BackgroundTasks.request_cancel_for_lifecycle_message!(message_id)
              queue = lock_active_queue!(chat_id)
              actor = %User{id: owner_id}
              converted = convert_pending_steers!(queue, message, status, actor)
              affected = apply_follow_up_boundary!(queue, message, status, actor)

              %{
                chat_id: chat_id,
                message_id: message_id,
                status: status,
                converted_steers: converted,
                affected_follow_ups: affected
              }
          end
        end)
        |> unwrap_result()

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def settle_generation(_message_id, _status), do: {:error, :invalid_generation}

  @doc "Atomically cancels a generation, blocks its queue, and records its terminal event."
  @spec cancel_generation(integer(), keyword()) ::
          :canceled | :not_generating | :not_found | {:error, term()}
  def cancel_generation(message_id, opts \\ [])

  def cancel_generation(message_id, opts) when is_integer(message_id) and is_list(opts) do
    terminate_generation(message_id, :canceled, opts)
  end

  def cancel_generation(_message_id, _opts), do: :not_found

  @doc """
  Atomically fails a generation that can no longer run, blocks its queue, and
  records its terminal event. The failure notification is dispatched after commit.
  """
  @spec fail_generation(integer(), keyword()) ::
          :failed | :not_generating | :not_found | {:error, term()}
  def fail_generation(message_id, opts \\ [])

  def fail_generation(message_id, opts) when is_integer(message_id) and is_list(opts) do
    case terminate_generation(message_id, :error, opts) do
      :failed = result ->
        NotificationsDispatcher.notify_generation_finished(message_id, :error)
        result

      result ->
        result
    end
  end

  def fail_generation(_message_id, _opts), do: :not_found

  defp terminate_generation(message_id, status, opts) do
    case message_chat_owner(message_id) do
      {:ok, %{chat_id: chat_id, owner_id: owner_id}} ->
        transact(fn ->
          _chat = lock_chat!(chat_id)
          message = lock_message!(message_id)

          if message.chat_id == chat_id and message.role == :assistant and
               message.status == :generating do
            case persist_terminal_generation!(message_id, status, opts) do
              result when result in [:canceled, :failed] ->
                terminated_message = lock_message!(message_id)
                queue = lock_active_queue!(chat_id)
                actor = %User{id: owner_id}
                _ = convert_pending_steers!(queue, terminated_message, status, actor)
                _ = apply_follow_up_boundary!(queue, terminated_message, status, actor)
                _ = BackgroundTasks.request_cancel_for_lifecycle_message!(message_id)
                record_terminal_event!(message_id, status)
                result

              result ->
                result
            end
          else
            :not_generating
          end
        end)
        |> unwrap_terminate_result()
        |> then(fn
          result when result in [:canceled, :failed] ->
            BackgroundTasks.cancel_for_lifecycle_message_async(message_id)
            result

          result ->
            result
        end)

      {:error, :not_found} ->
        :not_found
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp persist_terminal_generation!(message_id, :canceled, opts),
    do: Persistence.cancel_generating_message!(message_id, opts)

  defp persist_terminal_generation!(message_id, :error, opts),
    do: Persistence.fail_generating_message!(message_id, opts)

  @doc "Atomically prepares a tool-handoff child generation and moves the source backlog."
  @spec prepare_terminal_handoff(integer(), integer()) ::
          {:ok, map()} | {:error, term()}
  def prepare_terminal_handoff(source_message_id, child_chat_id)
      when is_integer(source_message_id) and is_integer(child_chat_id) do
    with {:ok, %{chat_id: source_chat_id, owner_id: owner_id}} <-
           message_chat_owner(source_message_id) do
      transact(fn ->
        chats = lock_chats!([source_chat_id, child_chat_id])
        source_chat = Map.fetch!(chats, source_chat_id)
        child_chat = Map.fetch!(chats, child_chat_id)
        source_message = lock_message!(source_message_id)

        cond do
          source_chat.owner_id != owner_id or child_chat.owner_id != owner_id or
              source_message.chat_id != source_chat.id ->
            {:error, :handoff_owner_mismatch}

          true ->
            actor = %User{id: owner_id}

            {generation_message_id, queue_anchor_message_id, prepared_context, child_anchor} =
              ensure_handoff_generation!(child_chat, actor)

            source_chat
            |> move_handoff_queue!(
              child_chat,
              source_message,
              child_anchor,
              queue_anchor_message_id,
              actor
            )
            |> Map.merge(%{
              child_generation_message_id: generation_message_id,
              child_queue_anchor_message_id: queue_anchor_message_id,
              prepared_context: prepared_context
            })
        end
      end)
      |> unwrap_result()
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def prepare_terminal_handoff(_source_message_id, _child_chat_id),
    do: {:error, :invalid_handoff}

  @doc "Moves a source backlog into a terminal handoff child without changing FIFO ids."
  @spec transfer_to_handoff(integer(), integer(), integer() | nil) ::
          {:ok, map()} | {:error, term()}
  def transfer_to_handoff(source_message_id, child_chat_id, child_generation_message_id)
      when is_integer(source_message_id) and is_integer(child_chat_id) do
    with {:ok, %{chat_id: source_chat_id, owner_id: owner_id}} <-
           message_chat_owner(source_message_id) do
      transact(fn ->
        chats = lock_chats!([source_chat_id, child_chat_id])
        source_chat = Map.fetch!(chats, source_chat_id)
        child_chat = Map.fetch!(chats, child_chat_id)
        anchor_message_id = child_generation_message_id || child_chat.last_message_id

        messages = lock_messages!([source_message_id, anchor_message_id])
        source_message = Map.get(messages, source_message_id)
        child_anchor = Map.get(messages, anchor_message_id)

        cond do
          source_chat.owner_id != owner_id or child_chat.owner_id != owner_id or
            is_nil(source_message) or source_message.chat_id != source_chat.id ->
            {:error, :handoff_owner_mismatch}

          is_integer(child_generation_message_id) and
              (is_nil(child_anchor) or child_anchor.chat_id != child_chat.id or
                 child_anchor.role != :assistant) ->
            {:error, :invalid_child_generation}

          true ->
            actor = %User{id: owner_id}

            move_handoff_queue!(
              source_chat,
              child_chat,
              source_message,
              child_anchor,
              anchor_message_id,
              actor,
              child_generation_message_id
            )
        end
      end)
      |> unwrap_result()
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def transfer_to_handoff(_source_message_id, _child_chat_id, _child_generation_message_id),
    do: {:error, :invalid_handoff}

  @doc "Returns chats which may have an automatically dispatchable follow-up."
  @spec ready_chat_ids() :: [integer()]
  def ready_chat_ids do
    follow_up_chat_ids =
      QueuedMessage
      |> Ash.Query.filter(kind == :follow_up and status == :pending)
      |> Ash.Query.select([:chat_id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.chat_id)

    steer_chat_ids =
      QueuedMessage
      |> Ash.Query.filter(kind == :steer and status == :pending)
      |> Ash.Query.select([:chat_id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.chat_id)

    (follow_up_chat_ids ++ steer_chat_ids)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Rejects a direct turn while non-quarantined queue entries still need settlement."
  @spec ensure_direct_start_allowed(integer()) :: :ok | {:error, :queue_not_empty}
  def ensure_direct_start_allowed(chat_id) when is_integer(chat_id) do
    QueuedMessage
    |> Ash.Query.filter(
      chat_id == ^chat_id and status in ^@active_queue_statuses and
        (kind != :steer or status != :blocked or is_nil(blocked_reason) or
           blocked_reason != "steering_failed")
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> :ok
      %QueuedMessage{} -> {:error, :queue_not_empty}
    end
  end

  defp prepare_direct_attempt(chat_id, opts, attempts) do
    with :ok <- direct_preflight(chat_id, Keyword.get(opts, :actor)) do
      case Context.prepare(chat_id, opts) do
        {:ok, preparation} -> prepare_direct_locked(chat_id, opts, nil, preparation)
        {:fallback, _reason} -> prepare_direct_locked(chat_id, opts, nil, nil)
        {:error, %StalePreparationError{} = error} -> raise error
        {:error, _reason} = error -> error
      end
    end
  rescue
    _error in StalePreparationError ->
      if attempts > 0 do
        prepare_direct_attempt(chat_id, opts, attempts - 1)
      else
        prepare_direct_locked(chat_id, opts, nil, nil)
      end
  end

  defp direct_preflight(chat_id, %{id: actor_id} = actor) do
    case Ash.get(Chat, chat_id, actor: actor, authorize?: true) do
      {:ok, %Chat{owner_id: ^actor_id}} ->
        active =
          ChatMessage
          |> Ash.Query.filter(chat_id == ^chat_id and status == :generating)
          |> Ash.Query.select([:id])
          |> Ash.Query.limit(1)
          |> Ash.read_one!(actor: actor, authorize?: true)

        queued =
          QueuedMessage
          |> Ash.Query.filter(
            chat_id == ^chat_id and status in ^@active_queue_statuses and
              (kind != :steer or status != :blocked or is_nil(blocked_reason) or
                 blocked_reason != "steering_failed")
          )
          |> Ash.Query.select([:id])
          |> Ash.Query.limit(1)
          |> Ash.read_one!(actor: actor, authorize?: true)

        cond do
          not is_nil(active) -> {:error, :generation_active}
          not is_nil(queued) -> {:error, :queue_not_empty}
          true -> :ok
        end

      _unavailable ->
        {:error, :forbidden}
    end
  end

  defp direct_preflight(_chat_id, _actor), do: {:error, :forbidden}

  defp prepare_direct_locked(chat_id, opts, prepare_parent, preparation) do
    actor = Keyword.get(opts, :actor)

    transact(fn ->
      chat = lock_chat!(chat_id)
      active_generation = lock_active_generation(chat.id)
      queue = Enum.reject(lock_active_queue!(chat.id), &quarantined_steer?/1)

      cond do
        is_nil(actor) or Map.get(actor, :id) != chat.owner_id ->
          {:error, :forbidden}

        match?(%ChatMessage{}, active_generation) ->
          {:error, :generation_active}

        queue != [] ->
          {:error, :queue_not_empty}

        not is_nil(preparation) ->
          {:ok, Context.publish!(preparation, actor: actor)}

        true ->
          case prepare_direct_context_opts(opts, prepare_parent) do
            {:ok, context_opts} -> {:ok, Context.build!(chat.id, context_opts)}
            {:error, reason} -> raise PublicationError, reason: reason
          end
      end
    end)
    |> unwrap_prepare_result()
  end

  defp quarantined_steer?(%{kind: :steer, status: :blocked, blocked_reason: "steering_failed"}),
    do: true

  defp quarantined_steer?(_queued_message), do: false

  defp prepare_next_attempt(chat_id, boundary_message_id, attempts) do
    case transact(fn -> prepare_next_in_transaction(chat_id, boundary_message_id, :snapshot) end) do
      {:ok, {:candidate, ticket}} ->
        opts = [
          actor: ticket.actor,
          parent_id: ticket.parent_id,
          pending_user_contents: ticket.contents
        ]

        case Context.prepare(chat_id, opts) do
          {:ok, preparation} ->
            transact(fn ->
              prepare_next_in_transaction(
                chat_id,
                boundary_message_id,
                {:prepared, ticket, preparation}
              )
            end)
            |> unwrap_prepare_result()

          {:fallback, _reason} ->
            prepare_next_locked(chat_id, boundary_message_id)

          {:error, %StalePreparationError{} = error} ->
            raise error

          {:error, _reason} = error ->
            error
        end

      result ->
        unwrap_prepare_result(result)
    end
  rescue
    _error in StalePreparationError ->
      if attempts > 0 do
        prepare_next_attempt(chat_id, boundary_message_id, attempts - 1)
      else
        prepare_next_locked(chat_id, boundary_message_id)
      end
  end

  defp prepare_next_locked(chat_id, boundary_message_id) do
    transact(fn -> prepare_next_in_transaction(chat_id, boundary_message_id, :locked) end)
    |> unwrap_prepare_result()
  end

  defp prepare_next_in_transaction(chat_id, _boundary_message_id, mode) do
    chat = lock_chat!(chat_id)

    case lock_active_generation(chat.id) do
      %ChatMessage{} ->
        :active

      nil ->
        settle_terminal_steers_for_chat!(chat)

        case peek_head_follow_up(chat.id) do
          nil ->
            :empty

          %QueuedMessage{} = peeked ->
            anchor = lock_optional_message!(peeked.anchor_message_id)
            queue = lock_active_queue!(chat.id)
            settle_recovered_boundary!(queue, anchor, chat.owner_id)

            backlog =
              chat.id
              |> lock_active_queue!()
              |> Enum.filter(&(&1.kind == :follow_up))

            prepare_locked_head(chat, backlog, mode)
        end
    end
  end

  defp prepare_locked_head(_chat, [], _mode), do: :empty

  defp prepare_locked_head(%Chat{} = chat, [%QueuedMessage{} = head | rest], mode) do
    cond do
      head.status == :blocked ->
        {:blocked, head.blocked_reason || :blocked}

      head.status != :pending ->
        {:blocked, :queue_head_not_pending}

      head.anchor_message_id != chat.last_message_id ->
        actor = %User{id: chat.owner_id}

        Enum.each([head | rest], fn queued_message ->
          update_queue!(
            queued_message,
            %{status: :blocked, blocked_reason: "branch_changed", finished_at: nil},
            actor
          )
        end)

        {:blocked, :branch_changed}

      true ->
        actor = %User{id: chat.owner_id}
        head = Ash.load!(head, [contents: [:file]], actor: actor, authorize?: true)
        contents = QueuedMessages.content_specs(head)

        if contents == [] do
          update_queue!(
            head,
            %{status: :blocked, blocked_reason: "empty_message", finished_at: nil},
            actor
          )

          {:blocked, :empty_message}
        else
          if mode == :snapshot and Enum.all?(contents, &(&1.kind == :text)) do
            {:candidate,
             %{
               actor: actor,
               parent_id: head.anchor_message_id,
               revision: queue_head_revision(head),
               contents: contents
             }}
          else
            context = publish_queue_context!(chat, head, contents, actor, mode)
            finalize_queued_turn!(head, rest, context, actor)
          end
        end
    end
  end

  defp publish_queue_context!(chat, head, _contents, actor, {:prepared, ticket, preparation}) do
    if ticket.revision != queue_head_revision(head) do
      raise StalePreparationError, chat_id: chat.id
    end

    Context.publish!(preparation, actor: actor)
  end

  defp publish_queue_context!(chat, head, contents, actor, _locked_or_media) do
    user_message = create_user_message!(chat.id, head.anchor_message_id, contents, actor)
    Context.build!(chat.id, actor: actor, parent_id: user_message.id)
  end

  defp finalize_queued_turn!(head, rest, context, actor) do
    case QueuedMessages.mark_delivered(
           head,
           %{
             user_message_id: context.parent_message_id,
             assistant_message_id: context.message_id
           },
           actor
         ) do
      {:ok, _delivered} -> :ok
      {:error, reason} -> raise "Failed to finalize queued delivery: #{inspect(reason)}"
    end

    Enum.each(rest, fn queued_message ->
      update_queue!(queued_message, %{anchor_message_id: context.message_id}, actor)
    end)

    {:ok, context}
  end

  defp queue_head_revision(head) do
    contents =
      head.contents
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&Map.take(&1, [:id, :updated_at, :sequence, :kind, :content_text, :file_id]))

    {Map.take(head, [:id, :owner_id, :chat_id, :kind, :status, :anchor_message_id, :updated_at]),
     contents}
  end

  defp create_user_message!(chat_id, parent_id, contents, actor) do
    ChatMessage
    |> Ash.Changeset.for_create(
      :add_user_message_with_contents,
      %{
        chat_id: chat_id,
        parent_id: parent_id,
        contents: contents,
        use_active_leaf_parent: false
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp convert_pending_steers!(queue, message, status, actor) do
    queue
    |> Enum.filter(fn queued_message ->
      queued_message.kind == :steer and queued_message.status == :pending and
        queued_message.target_generation_message_id == message.id
    end)
    |> Enum.map(fn queued_message ->
      update_queue!(
        queued_message,
        %{
          kind: :follow_up,
          status: terminal_follow_up_status(status),
          blocked_reason: terminal_block_reason(status),
          anchor_message_id: message.id,
          target_generation_message_id: nil,
          finished_at: nil
        },
        actor
      )
    end)
    |> length()
  end

  defp apply_follow_up_boundary!(queue, message, :done, actor) do
    queue
    |> Enum.filter(fn queued_message ->
      queued_message.kind == :follow_up and queued_message.status == :blocked and
        queued_message.anchor_message_id == message.id and
        queued_message.blocked_reason in @terminal_block_reasons
    end)
    |> Enum.map(fn queued_message ->
      update_queue!(
        queued_message,
        %{status: :pending, blocked_reason: nil, finished_at: nil},
        actor
      )
    end)
    |> length()
  end

  defp apply_follow_up_boundary!(queue, message, status, actor)
       when status in [:error, :canceled] do
    reason = terminal_block_reason(status)

    queue
    |> Enum.filter(fn queued_message ->
      queued_message.kind == :follow_up and
        queued_message.anchor_message_id == message.id
    end)
    |> Enum.map(fn queued_message ->
      update_queue!(
        queued_message,
        %{status: :blocked, blocked_reason: reason, finished_at: nil},
        actor
      )
    end)
    |> length()
  end

  defp terminal_follow_up_status(:done), do: :pending
  defp terminal_follow_up_status(status) when status in [:error, :canceled], do: :blocked

  defp terminal_block_reason(:done), do: nil
  defp terminal_block_reason(:error), do: "generation_error"
  defp terminal_block_reason(:canceled), do: "generation_canceled"

  defp handoff_destination_state(%ChatMessage{role: :assistant, status: :error}),
    do: {:blocked, "generation_error"}

  defp handoff_destination_state(%ChatMessage{role: :assistant, status: :canceled}),
    do: {:blocked, "generation_canceled"}

  defp handoff_destination_state(_anchor), do: {:pending, nil}

  defp ensure_handoff_generation!(%Chat{} = child_chat, actor) do
    first_generation =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^child_chat.id and role == :assistant)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(1)
      |> Ash.Query.lock("FOR NO KEY UPDATE")
      |> Ash.read_one!(authorize?: false)

    case first_generation do
      nil ->
        context = Context.build!(child_chat.id, actor: actor)
        child_anchor = lock_message!(context.message_id)
        {context.message_id, context.message_id, context, child_anchor}

      %ChatMessage{} = generation ->
        last_message =
          if child_chat.last_message_id == generation.id do
            generation
          else
            lock_optional_message!(child_chat.last_message_id)
          end

        child_anchor =
          case last_message do
            %ChatMessage{chat_id: chat_id, role: :assistant} = message
            when chat_id == child_chat.id ->
              message

            _other ->
              generation
          end

        {generation.id, child_anchor.id, nil, child_anchor}
    end
  end

  defp move_handoff_queue!(
         %Chat{} = source_chat,
         %Chat{} = child_chat,
         %ChatMessage{} = source_message,
         child_anchor,
         anchor_message_id,
         actor,
         child_generation_message_id \\ nil
       ) do
    queue = lock_active_queue!(source_chat.id)

    transferable =
      Enum.filter(queue, fn queued_message ->
        queued_message.kind == :follow_up or
          (queued_message.kind == :steer and
             queued_message.blocked_reason != "steering_failed" and
             queued_message.target_generation_message_id == source_message.id)
      end)

    {destination_status, blocked_reason} = handoff_destination_state(child_anchor)

    Enum.each(transferable, fn queued_message ->
      update_queue!(
        queued_message,
        %{
          chat_id: child_chat.id,
          kind: :follow_up,
          status: destination_status,
          blocked_reason: blocked_reason,
          anchor_message_id: anchor_message_id,
          target_generation_message_id: nil,
          finished_at: nil
        },
        actor
      )
    end)

    %{
      source_chat_id: source_chat.id,
      child_chat_id: child_chat.id,
      child_generation_message_id: child_generation_message_id,
      child_generation_status: child_anchor && child_anchor.status,
      transferred_count: length(transferable)
    }
  end

  defp settle_recovered_boundary!(
         queue,
         %ChatMessage{role: :assistant, status: status} = anchor,
         owner_id
       )
       when status in [:done, :error, :canceled] do
    actor = %User{id: owner_id}
    _ = convert_pending_steers!(queue, anchor, status, actor)
    _ = apply_follow_up_boundary!(queue, anchor, status, actor)
    :ok
  end

  defp settle_recovered_boundary!(_queue, _anchor, _owner_id), do: :ok

  defp settle_terminal_steers_for_chat!(%Chat{} = chat) do
    target_ids =
      QueuedMessage
      |> Ash.Query.filter(chat_id == ^chat.id and kind == :steer and status == :pending)
      |> Ash.Query.select([:target_generation_message_id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.target_generation_message_id)
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Enum.sort()

    messages = lock_messages!(target_ids)
    queue = lock_active_queue!(chat.id)
    actor = %User{id: chat.owner_id}

    messages
    |> Map.values()
    |> Enum.filter(&(&1.role == :assistant and &1.status in [:done, :error, :canceled]))
    |> Enum.sort_by(& &1.id)
    |> Enum.each(fn message ->
      _ = convert_pending_steers!(queue, message, message.status, actor)
      _ = apply_follow_up_boundary!(queue, message, message.status, actor)
    end)

    :ok
  end

  defp prepare_direct_context_opts(opts, nil), do: {:ok, opts}

  defp prepare_direct_context_opts(opts, prepare_parent) when is_function(prepare_parent, 0) do
    case prepare_parent.() do
      {:ok, %ChatMessage{id: parent_id}} when is_integer(parent_id) ->
        {:ok, Keyword.put(opts, :parent_id, parent_id)}

      {:ok, parent_id} when is_integer(parent_id) ->
        {:ok, Keyword.put(opts, :parent_id, parent_id)}

      {:ok, parent_opts} when is_list(parent_opts) ->
        {:ok, Keyword.merge(opts, parent_opts)}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_direct_generation_parent, other}}
    end
  end

  defp lock_chat!(chat_id) do
    Chat
    |> Ash.Query.filter(id == ^chat_id)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %Chat{} = chat -> chat
      nil -> raise ArgumentError, "Chat not found"
    end
  end

  defp lock_chats!(chat_ids) do
    ids = chat_ids |> Enum.filter(&is_integer/1) |> Enum.uniq() |> Enum.sort()

    chats =
      Chat
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock("FOR NO KEY UPDATE")
      |> Ash.read!(authorize?: false)

    if length(chats) == length(ids) do
      Map.new(chats, &{&1.id, &1})
    else
      raise ArgumentError, "Handoff chat not found"
    end
  end

  defp lock_message!(message_id) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %ChatMessage{} = message -> message
      nil -> raise ArgumentError, "Chat message not found"
    end
  end

  defp lock_messages!([]), do: %{}

  defp lock_messages!(message_ids) when is_list(message_ids) do
    ids = message_ids |> Enum.filter(&is_integer/1) |> Enum.uniq() |> Enum.sort()

    ChatMessage
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, &1})
  end

  defp lock_optional_message!(message_id) when is_integer(message_id),
    do: lock_message!(message_id)

  defp lock_optional_message!(_message_id), do: nil

  defp lock_active_generation(chat_id) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id and status == :generating)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read_one!(authorize?: false)
  end

  defp peek_head_follow_up(chat_id) do
    QueuedMessage
    |> Ash.Query.filter(
      chat_id == ^chat_id and kind == :follow_up and status in ^@active_queue_statuses
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp lock_active_queue!(chat_id) do
    QueuedMessage
    |> Ash.Query.filter(chat_id == ^chat_id and status in ^@active_queue_statuses)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(authorize?: false)
  end

  defp update_queue!(queued_message, attrs, actor) do
    queued_message
    |> Ash.Changeset.for_update(:update_state, attrs, actor: actor, authorize?: false)
    |> Ash.update!(actor: actor, authorize?: false)
  end

  defp record_terminal_event!(message_id, status) do
    case Notifications.record_generation_finished(message_id, status) do
      {:ok, _event} ->
        :ok

      {:duplicate, _event} ->
        :ok

      {:error, reason} ->
        raise "Failed to record #{status} generation event: #{inspect(reason)}"
    end
  end

  defp message_chat_owner(message_id) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id)
    |> Ash.Query.select([:id, :chat_id, :owner_id])
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %ChatMessage{} = message ->
        {:ok, %{chat_id: message.chat_id, owner_id: message.owner_id}}

      nil ->
        {:error, :not_found}
    end
  end

  defp transact(fun) when is_function(fun, 0) do
    Ash.transaction(@transaction_resources, fun)
  end

  defp unwrap_prepare_result({:ok, {:ok, _context} = result}), do: result
  defp unwrap_prepare_result({:ok, result}) when result in [:empty, :active], do: result
  defp unwrap_prepare_result({:ok, {:blocked, _reason} = result}), do: result
  defp unwrap_prepare_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_prepare_result({:error, reason}), do: {:error, reason}

  defp unwrap_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_result({:ok, result}), do: {:ok, result}
  defp unwrap_result({:error, reason}), do: {:error, reason}

  defp unwrap_terminate_result({:ok, result}), do: result
  defp unwrap_terminate_result({:error, reason}), do: {:error, reason}
end
