defmodule IntellectualClub.Chat.QueuedMessages do
  @moduledoc """
  Durable queue operations for follow-up and steering chat messages.

  Public mutations require the chat owner as actor. Generation orchestration may
  use the explicitly documented internal helpers with authorization disabled.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.QueuedMessage
  alias IntellectualClub.Chat.QueuedMessageContent

  require Ash.Query

  @active_statuses [:pending, :blocked]
  @transaction_resources [Chat, ChatMessage, QueuedMessage, QueuedMessageContent]

  @type enqueue_attrs :: %{
          optional(:content) => String.t(),
          optional(:file_ids) => [integer()]
        }

  @doc "Enqueues a durable follow-up anchored to the current chat leaf."
  @spec enqueue_follow_up(integer(), enqueue_attrs(), map()) ::
          {:ok, QueuedMessage.t()} | {:error, term()}
  def enqueue_follow_up(chat_id, attrs, actor)
      when is_integer(chat_id) and is_map(attrs) and is_map(actor) do
    with {:ok, content, file_ids} <- normalize_contents(attrs),
         :ok <- validate_nonempty(content, file_ids) do
      transact(fn ->
        with {:ok, %Chat{} = chat} <- lock_owned_chat(chat_id, actor) do
          create_queued_message!(
            %{
              chat_id: chat.id,
              kind: :follow_up,
              anchor_message_id: chat.last_message_id
            },
            content,
            file_ids,
            actor
          )
        end
      end)
    end
  end

  @doc "Enqueues steering for an active assistant generation."
  @spec enqueue_steer(integer(), map() | String.t(), map()) ::
          {:ok, QueuedMessage.t()} | {:error, term()}
  def enqueue_steer(message_id, content_or_attrs, actor)
      when is_integer(message_id) and is_map(actor) do
    attrs =
      case content_or_attrs do
        %{} = attrs -> attrs
        content when is_binary(content) -> %{content: content}
        _other -> %{}
      end

    with {:ok, content, []} <- normalize_contents(Map.put(attrs, :file_ids, [])),
         :ok <- validate_nonempty(content, []),
         {:ok, %ChatMessage{} = preliminary} <- fetch_owned_generation(message_id, actor),
         :ok <- validate_steering_capability(preliminary) do
      transact(fn ->
        with {:ok, %Chat{} = chat} <- lock_owned_chat(preliminary.chat_id, actor),
             {:ok, %ChatMessage{} = message} <- lock_owned_generation(message_id, actor),
             :ok <- ensure_message_chat(message, chat),
             :ok <- validate_steering_capability(message) do
          enqueue_steer_for_generation_state!(message, content, actor)
        end
      end)
    end
  end

  @doc "Lists pending and blocked queue entries in FIFO order."
  @spec list_for_chat(integer(), map()) :: {:ok, [QueuedMessage.t()]} | {:error, term()}
  def list_for_chat(chat_id, actor) when is_integer(chat_id) and is_map(actor) do
    QueuedMessage
    |> Ash.Query.filter(chat_id == ^chat_id and status in ^@active_statuses)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(contents: [:file])
    |> Ash.read(actor: actor)
  end

  @doc "Returns an owned queue entry, including terminal entries."
  @spec get(integer(), map()) :: {:ok, QueuedMessage.t()} | {:error, term()}
  def get(id, actor) when is_integer(id) and is_map(actor) do
    case read_one(id, actor) do
      {:ok, %QueuedMessage{} = queued_message} -> {:ok, queued_message}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> normalize_read_error(error)
    end
  end

  @doc "Edits the text and attachment set of a pending or blocked queue entry."
  @spec update(integer(), map(), map()) :: {:ok, QueuedMessage.t()} | {:error, term()}
  def update(id, attrs, actor) when is_integer(id) and is_map(attrs) and is_map(actor) do
    with {:ok, file_ids} <- normalize_file_ids(value(attrs, :file_ids, [])),
         {:ok, remove_ids} <- normalize_remove_ids(value(attrs, :remove_content_ids, [])) do
      content_update = optional_string(attrs, :content)

      transact(fn ->
        with {:ok, %QueuedMessage{} = queued_message} <- lock_one(id, actor),
             :ok <- ensure_mutable(queued_message),
             :ok <- ensure_attachment_update_allowed(queued_message, file_ids),
             {:ok, current_contents} <- load_contents(queued_message, actor),
             :ok <- validate_media_removals(current_contents, remove_ids),
             :ok <-
               validate_update_nonempty(
                 current_contents,
                 content_update,
                 remove_ids,
                 file_ids
               ) do
          apply_content_update!(
            queued_message,
            current_contents,
            content_update,
            remove_ids,
            file_ids,
            actor
          )

          load_one!(queued_message.id, actor)
        end
      end)
    end
  end

  @doc "Cancels an entry that has not been delivered and releases its queued files."
  @spec cancel(integer(), map()) :: {:ok, QueuedMessage.t()} | {:error, term()}
  def cancel(id, actor) when is_integer(id) and is_map(actor) do
    with {:ok, preliminary} <- get(id, actor) do
      transact(fn ->
        with {:ok, %Chat{} = chat} <- lock_owned_chat(preliminary.chat_id, actor),
             {:ok, %QueuedMessage{} = queued_message} <- lock_one(id, actor),
             :ok <- ensure_mutable(queued_message),
             {:ok, contents} <- load_contents(queued_message, actor) do
          was_head? = follow_up_head?(queued_message, chat.id, actor)
          Enum.each(contents, &destroy_content!(&1, :destroy, actor))

          canceled =
            queued_message
            |> update_state!(
              %{status: :canceled, blocked_reason: nil, finished_at: now()},
              actor
            )

          if was_head?, do: pause_follow_up_backlog!(chat.id, actor)
          load_queue!(canceled, actor)
        end
      end)
    end
  end

  @doc "Retries the blocked head follow-up after explicitly re-anchoring the backlog."
  @spec send_next(integer(), map()) :: {:ok, QueuedMessage.t()} | {:error, term()}
  def send_next(id, actor) when is_integer(id) and is_map(actor) do
    with {:ok, preliminary} <- get(id, actor) do
      transact(fn ->
        with {:ok, %Chat{} = chat} <- lock_owned_chat(preliminary.chat_id, actor),
             :ok <- ensure_generation_idle(chat.id, actor),
             {:ok, %QueuedMessage{} = requested} <- lock_one(id, actor),
             :ok <- ensure_follow_up(requested),
             :ok <- ensure_mutable(requested),
             {:ok, %QueuedMessage{} = head} <- lock_head_follow_up(chat.id, actor),
             :ok <- ensure_requested_head(requested, head),
             {:ok, backlog} <- lock_follow_up_backlog(chat.id, actor) do
          Enum.each(backlog, fn queued_message ->
            update_state!(
              queued_message,
              %{
                status: :pending,
                blocked_reason: nil,
                anchor_message_id: chat.last_message_id,
                finished_at: nil
              },
              actor
            )
          end)

          head
          |> update_state!(
            %{
              status: :pending,
              blocked_reason: nil,
              anchor_message_id: chat.last_message_id
            },
            actor
          )
          |> load_queue!(actor)
        end
      end)
    end
  end

  @doc false
  @spec list_pending_steers(integer(), map() | nil) ::
          {:ok, [QueuedMessage.t()]} | {:error, term()}
  def list_pending_steers(target_generation_message_id, actor \\ nil)
      when is_integer(target_generation_message_id) do
    QueuedMessage
    |> Ash.Query.filter(
      kind == :steer and status == :pending and
        target_generation_message_id == ^target_generation_message_id
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(contents: [:file])
    |> Ash.read(ash_opts(actor))
  end

  @doc false
  @spec head_follow_up(integer(), map() | nil) ::
          {:ok, QueuedMessage.t() | nil} | {:error, term()}
  def head_follow_up(chat_id, actor \\ nil) when is_integer(chat_id) do
    QueuedMessage
    |> Ash.Query.filter(
      chat_id == ^chat_id and kind == :follow_up and status in ^@active_statuses
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(contents: [:file])
    |> Ash.read_one(ash_opts(actor))
  end

  @doc false
  @spec pending_follow_up?(integer(), map() | nil) :: boolean()
  def pending_follow_up?(chat_id, actor \\ nil) when is_integer(chat_id) do
    match?({:ok, %QueuedMessage{}}, head_follow_up(chat_id, actor))
  end

  @doc false
  @spec mark_blocked(QueuedMessage.t() | integer(), term(), map() | nil) ::
          {:ok, QueuedMessage.t()} | {:error, term()}
  def mark_blocked(queued_message_or_id, reason, actor \\ nil) do
    mutate_internal(queued_message_or_id, actor, fn queued_message ->
      update_state!(
        queued_message,
        %{
          status: :blocked,
          blocked_reason: normalize_reason(reason),
          attempt_count: queued_message.attempt_count + 1,
          finished_at: nil
        },
        actor
      )
    end)
  end

  @doc false
  @spec mark_pending(QueuedMessage.t() | integer(), map() | nil) ::
          {:ok, QueuedMessage.t()} | {:error, term()}
  def mark_pending(queued_message_or_id, actor \\ nil) do
    mutate_internal(queued_message_or_id, actor, fn queued_message ->
      update_state!(
        queued_message,
        %{status: :pending, blocked_reason: nil, finished_at: nil},
        actor
      )
    end)
  end

  @doc false
  @spec mark_delivered(QueuedMessage.t() | integer(), map(), map() | nil) ::
          {:ok, QueuedMessage.t()} | {:error, term()}
  def mark_delivered(queued_message_or_id, delivery_attrs, actor \\ nil)
      when is_map(delivery_attrs) do
    transact(fn ->
      with {:ok, %QueuedMessage{} = queued_message} <-
             resolve_locked(queued_message_or_id, actor),
           :ok <- ensure_mutable(queued_message),
           {:ok, contents} <- load_contents(queued_message, actor) do
        delivered =
          queued_message
          |> update_state!(
            delivery_attrs
            |> Map.take([:user_message_id, :assistant_message_id, :steering_item_id])
            |> Map.merge(%{
              status: :delivered,
              blocked_reason: nil,
              finished_at: now()
            }),
            actor
          )

        Enum.each(contents, &destroy_content!(&1, :destroy_after_transfer, actor))
        load_queue!(delivered, actor)
      end
    end)
  end

  @doc false
  @spec content_specs(QueuedMessage.t()) :: [map()]
  def content_specs(%QueuedMessage{} = queued_message) do
    queued_message
    |> Map.get(:contents, [])
    |> loaded_list()
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map(fn
      %QueuedMessageContent{kind: :text} = content ->
        %{kind: :text, content_text: content.content_text || ""}

      %QueuedMessageContent{kind: :media} = content ->
        %{kind: :media, file_id: content.file_id}
    end)
  end

  defp create_queued_message!(queue_attrs, content, file_ids, actor) do
    queued_message =
      QueuedMessage
      |> Ash.Changeset.for_create(:enqueue, queue_attrs, actor: actor)
      |> Ash.create!(actor: actor)

    content_specs(content, file_ids)
    |> Enum.with_index(1)
    |> Enum.each(fn {attrs, sequence} ->
      QueuedMessageContent
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(attrs, %{queued_message_id: queued_message.id, sequence: sequence}),
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end)

    load_queue!(queued_message, actor)
  end

  defp content_specs(content, file_ids) do
    text_specs = if content == "", do: [], else: [%{kind: :text, content_text: content}]
    text_specs ++ Enum.map(file_ids, &%{kind: :media, file_id: &1})
  end

  defp normalize_contents(attrs) do
    content = attrs |> value(:content, "") |> to_string()

    with {:ok, file_ids} <- normalize_file_ids(value(attrs, :file_ids, [])) do
      {:ok, content, file_ids}
    end
  end

  defp normalize_file_ids(file_ids) do
    file_ids
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn
      id, {:ok, acc} when is_integer(id) and id > 0 ->
        {:cont, {:ok, Enum.uniq(acc ++ [id])}}

      _other, _acc ->
        {:halt, {:error, :invalid_file_ids}}
    end)
  end

  defp normalize_remove_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case parse_id(value) do
        id when is_integer(id) and id > 0 -> {:cont, {:ok, Enum.uniq(acc ++ [id])}}
        _other -> {:halt, {:error, :invalid_remove_content_ids}}
      end
    end)
  end

  defp parse_id(value) when is_integer(value), do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _other -> nil
    end
  end

  defp parse_id(_value), do: nil

  defp validate_nonempty("", []), do: {:error, :empty_message}
  defp validate_nonempty(_content, _file_ids), do: :ok

  defp validate_update_nonempty(contents, content_update, remove_ids, file_ids) do
    current_text? = Enum.any?(contents, &(&1.kind == :text and &1.content_text != ""))

    text? =
      case content_update do
        :missing -> current_text?
        {:present, content} -> content != ""
      end

    retained_media? =
      Enum.any?(contents, fn content ->
        content.kind == :media and content.id not in remove_ids
      end)

    if text? or retained_media? or file_ids != [], do: :ok, else: {:error, :empty_message}
  end

  defp validate_media_removals(contents, remove_ids) do
    media_ids =
      contents
      |> Enum.filter(&(&1.kind == :media))
      |> MapSet.new(& &1.id)

    if Enum.all?(remove_ids, &MapSet.member?(media_ids, &1)) do
      :ok
    else
      {:error, :invalid_remove_content_ids}
    end
  end

  defp apply_content_update!(
         queued_message,
         current_contents,
         content_update,
         remove_ids,
         file_ids,
         actor
       ) do
    current_contents
    |> Enum.filter(&(&1.id in remove_ids))
    |> Enum.each(&destroy_content!(&1, :destroy, actor))

    apply_text_update!(queued_message, current_contents, content_update, actor)

    next_sequence =
      current_contents
      |> Enum.reject(&(&1.id in remove_ids))
      |> Enum.map(& &1.sequence)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    file_ids
    |> Enum.with_index(next_sequence)
    |> Enum.each(fn {file_id, sequence} ->
      QueuedMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          queued_message_id: queued_message.id,
          sequence: sequence,
          kind: :media,
          file_id: file_id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end)

    queued_message
    |> load_contents!(actor)
    |> resequence_contents!(actor)
  end

  defp apply_text_update!(_queued_message, _contents, :missing, _actor), do: :ok

  defp apply_text_update!(_queued_message, contents, {:present, ""}, actor) do
    contents
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.each(&destroy_content!(&1, :destroy, actor))

    :ok
  end

  defp apply_text_update!(queued_message, contents, {:present, text}, actor) do
    case Enum.filter(contents, &(&1.kind == :text)) do
      [first | duplicates] ->
        first
        |> Ash.Changeset.for_update(:update, %{content_text: text}, actor: actor)
        |> Ash.update!(actor: actor)

        Enum.each(duplicates, &destroy_content!(&1, :destroy, actor))

      [] ->
        QueuedMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            queued_message_id: queued_message.id,
            sequence: next_sequence(contents),
            kind: :text,
            content_text: text
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)
    end

    :ok
  end

  defp next_sequence(contents) do
    contents
    |> Enum.map(& &1.sequence)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp resequence_contents!(contents, actor) do
    ordered = Enum.sort_by(contents, &{if(&1.kind == :text, do: 0, else: 1), &1.sequence, &1.id})
    temporary_start = next_sequence(contents) + length(contents) + 100

    temporary =
      ordered
      |> Enum.with_index(temporary_start)
      |> Enum.map(fn {content, sequence} ->
        content
        |> Ash.Changeset.for_update(:update, %{sequence: sequence}, actor: actor)
        |> Ash.update!(actor: actor)
      end)

    temporary
    |> Enum.with_index(1)
    |> Enum.each(fn {content, sequence} ->
      content
      |> Ash.Changeset.for_update(:update, %{sequence: sequence}, actor: actor)
      |> Ash.update!(actor: actor)
    end)

    :ok
  end

  defp lock_owned_chat(chat_id, actor) do
    Chat
    |> Ash.Query.filter(id == ^chat_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %Chat{owner_id: owner_id} = chat} when owner_id == actor.id -> {:ok, chat}
      {:ok, %Chat{}} -> {:error, :forbidden}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> normalize_read_error(error)
    end
  end

  defp fetch_owned_generation(message_id, actor) do
    case Ash.get(ChatMessage, message_id, actor: actor, load: [:llm_configuration]) do
      {:ok, %ChatMessage{owner_id: owner_id} = message} when owner_id == actor.id ->
        {:ok, message}

      {:ok, %ChatMessage{}} ->
        {:error, :forbidden}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, error} ->
        normalize_read_error(error)
    end
  end

  defp lock_owned_generation(message_id, actor) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.load(:llm_configuration)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %ChatMessage{owner_id: owner_id} = message} when owner_id == actor.id ->
        {:ok, message}

      {:ok, %ChatMessage{}} ->
        {:error, :forbidden}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, error} ->
        normalize_read_error(error)
    end
  end

  defp validate_steering_capability(%ChatMessage{role: :assistant, status: status} = message)
       when status in [:generating, :done, :error, :canceled] do
    case Map.get(message, :llm_configuration) do
      %{supports_steering: value} when value != false -> :ok
      _other when status != :generating -> {:error, :generation_not_active}
      _other -> {:error, :steering_not_supported}
    end
  end

  defp validate_steering_capability(%ChatMessage{}), do: {:error, :generation_not_active}

  defp enqueue_steer_for_generation_state!(
         %ChatMessage{role: :assistant, status: :generating} = message,
         content,
         actor
       ) do
    create_queued_message!(
      %{
        chat_id: message.chat_id,
        kind: :steer,
        target_generation_message_id: message.id
      },
      content,
      [],
      actor
    )
  end

  defp enqueue_steer_for_generation_state!(
         %ChatMessage{role: :assistant, status: status} = message,
         content,
         actor
       )
       when status in [:done, :error, :canceled] do
    destination = late_follow_up_destination(message, actor)

    queued_message =
      create_queued_message!(
        %{
          chat_id: destination.chat_id,
          kind: :follow_up,
          anchor_message_id: destination.anchor_message_id
        },
        content,
        [],
        actor
      )

    case destination.status do
      :pending ->
        queued_message

      :blocked ->
        queued_message
        |> update_state!(
          %{status: :blocked, blocked_reason: destination.blocked_reason, finished_at: nil},
          actor
        )
        |> load_queue!(actor)
    end
  end

  defp enqueue_steer_for_generation_state!(%ChatMessage{}, _content, _actor),
    do: {:error, :generation_not_active}

  defp late_follow_up_destination(%ChatMessage{status: :done} = message, actor) do
    case committed_handoff_child(message, actor) do
      %Chat{} = child ->
        destination_for_anchor(child.id, child.last_message_id, :done, actor)

      nil ->
        destination_for_anchor(message.chat_id, message.id, message.status, actor)
    end
  end

  defp late_follow_up_destination(%ChatMessage{} = message, actor) do
    destination_for_anchor(message.chat_id, message.id, message.status, actor)
  end

  defp committed_handoff_child(%ChatMessage{} = message, actor) do
    case committed_handoff_child_id(message, actor) do
      child_chat_id when is_integer(child_chat_id) ->
        handoff_child_query(message)
        |> Ash.Query.filter(id == ^child_chat_id)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(actor: actor)

      _other ->
        handoff_child_query(message)
        |> Ash.Query.filter(is_nil(parent_tool_call_item_id))
        |> Ash.Query.sort(id: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(actor: actor)
    end
  end

  defp handoff_child_query(%ChatMessage{} = message) do
    Chat
    |> Ash.Query.filter(
      parent_chat_id == ^message.chat_id and parent_message_id == ^message.id and
        parent_relation_kind == :handoff
    )
  end

  defp committed_handoff_child_id(%ChatMessage{} = message, actor) do
    message
    |> Ash.load!([steps: [items: [:contents]]], actor: actor)
    |> Map.get(:steps, [])
    |> Enum.flat_map(&List.wrap(&1.items))
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&List.wrap(&1.contents))
    |> Enum.find_value(fn
      %{kind: :opaque, content_json: %{"raw" => %{"handoff" => handoff}}}
      when is_map(handoff) ->
        case handoff do
          %{"chat_id" => chat_id, "generation_message_id" => generation_message_id}
          when is_integer(chat_id) and is_integer(generation_message_id) ->
            chat_id

          _other ->
            nil
        end

      _other ->
        nil
    end)
  end

  defp destination_for_anchor(chat_id, anchor_message_id, fallback_status, actor) do
    anchor_status =
      if is_integer(anchor_message_id) do
        case Ash.get(ChatMessage, anchor_message_id, actor: actor) do
          {:ok, %ChatMessage{status: status}} -> status
          _other -> fallback_status
        end
      else
        fallback_status
      end

    case anchor_status do
      :error ->
        %{
          chat_id: chat_id,
          anchor_message_id: anchor_message_id,
          status: :blocked,
          blocked_reason: "generation_error"
        }

      :canceled ->
        %{
          chat_id: chat_id,
          anchor_message_id: anchor_message_id,
          status: :blocked,
          blocked_reason: "generation_canceled"
        }

      _other ->
        %{
          chat_id: chat_id,
          anchor_message_id: anchor_message_id,
          status: :pending,
          blocked_reason: nil
        }
    end
  end

  defp ensure_message_chat(%ChatMessage{chat_id: chat_id}, %Chat{id: chat_id}), do: :ok
  defp ensure_message_chat(%ChatMessage{}, %Chat{}), do: {:error, :generation_not_active}

  defp ensure_generation_idle(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id and status == :generating)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> :ok
      {:ok, %ChatMessage{}} -> {:error, :generation_active}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_follow_up(%QueuedMessage{kind: :follow_up}), do: :ok
  defp ensure_follow_up(%QueuedMessage{}), do: {:error, :follow_up_required}

  defp ensure_attachment_update_allowed(%QueuedMessage{kind: :steer}, file_ids)
       when file_ids != [],
       do: {:error, :steer_attachments_not_supported}

  defp ensure_attachment_update_allowed(%QueuedMessage{}, _file_ids), do: :ok

  defp ensure_mutable(%QueuedMessage{status: status}) when status in @active_statuses, do: :ok
  defp ensure_mutable(%QueuedMessage{}), do: {:error, :already_dispatched}

  defp ensure_requested_head(%QueuedMessage{id: id}, %QueuedMessage{id: id}), do: :ok
  defp ensure_requested_head(%QueuedMessage{}, %QueuedMessage{}), do: {:error, :not_queue_head}

  defp follow_up_head?(%QueuedMessage{kind: :follow_up, id: id}, chat_id, actor) do
    case lock_head_follow_up(chat_id, actor) do
      {:ok, %QueuedMessage{id: ^id}} -> true
      _other -> false
    end
  end

  defp follow_up_head?(%QueuedMessage{}, _chat_id, _actor), do: false

  defp pause_follow_up_backlog!(chat_id, actor) do
    case lock_follow_up_backlog(chat_id, actor) do
      {:ok, backlog} ->
        Enum.each(backlog, fn queued_message ->
          update_state!(
            queued_message,
            %{status: :blocked, blocked_reason: "head_removed", finished_at: nil},
            actor
          )
        end)

      {:error, reason} ->
        raise "Failed to pause queued backlog after removing its head: #{inspect(reason)}"
    end
  end

  defp lock_head_follow_up(chat_id, actor) do
    QueuedMessage
    |> Ash.Query.filter(
      chat_id == ^chat_id and kind == :follow_up and status in ^@active_statuses
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %QueuedMessage{} = queued_message} -> {:ok, queued_message}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp lock_follow_up_backlog(chat_id, actor) do
    QueuedMessage
    |> Ash.Query.filter(
      chat_id == ^chat_id and kind == :follow_up and status in ^@active_statuses
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read(actor: actor)
  end

  defp lock_one(id, actor) do
    QueuedMessage
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %QueuedMessage{} = queued_message} -> {:ok, queued_message}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> normalize_read_error(error)
    end
  end

  defp resolve_locked(%QueuedMessage{id: id}, actor), do: lock_one_internal(id, actor)
  defp resolve_locked(id, actor) when is_integer(id), do: lock_one_internal(id, actor)
  defp resolve_locked(_other, _actor), do: {:error, :not_found}

  defp lock_one_internal(id, actor) do
    QueuedMessage
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(ash_opts(actor))
    |> case do
      {:ok, %QueuedMessage{} = queued_message} -> {:ok, queued_message}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp mutate_internal(queued_message_or_id, actor, fun) when is_function(fun, 1) do
    transact(fn ->
      with {:ok, %QueuedMessage{} = queued_message} <-
             resolve_locked(queued_message_or_id, actor),
           :ok <- ensure_mutable(queued_message) do
        queued_message
        |> fun.()
        |> load_queue!(actor)
      end
    end)
  end

  defp read_one(id, actor) do
    QueuedMessage
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(contents: [:file])
    |> Ash.read_one(actor: actor)
  end

  defp load_one!(id, actor) do
    QueuedMessage
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(contents: [:file])
    |> Ash.read_one!(actor: actor)
  end

  defp load_queue!(%QueuedMessage{} = queued_message, actor) do
    Ash.load!(queued_message, [contents: [:file]], ash_opts(actor))
  end

  defp load_contents(%QueuedMessage{} = queued_message, actor) do
    case Ash.load(queued_message, [contents: [:file]], ash_opts(actor)) do
      {:ok, loaded} -> {:ok, loaded.contents |> loaded_list() |> Enum.sort_by(& &1.sequence)}
      {:error, error} -> {:error, error}
    end
  end

  defp load_contents!(%QueuedMessage{} = queued_message, actor) do
    queued_message
    |> Ash.load!(:contents, ash_opts(actor))
    |> Map.get(:contents)
    |> loaded_list()
  end

  defp loaded_list(%Ash.NotLoaded{}), do: []
  defp loaded_list(value) when is_list(value), do: value
  defp loaded_list(_value), do: []

  defp update_state!(queued_message, attrs, actor) do
    queued_message
    |> Ash.Changeset.for_update(:update_state, attrs, ash_opts(actor))
    |> Ash.update!(ash_opts(actor))
  end

  defp destroy_content!(content, action, actor) do
    content
    |> Ash.Changeset.for_destroy(action, %{}, ash_opts(actor))
    |> Ash.destroy!(ash_opts(actor))
  end

  defp transact(fun) when is_function(fun, 0) do
    case Ash.transaction(@transaction_resources, fun) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_read_error(%Ash.Error.Forbidden{}), do: {:error, :forbidden}
  defp normalize_read_error(%Ash.Error.Query.NotFound{}), do: {:error, :not_found}

  defp normalize_read_error(%Ash.Error.Invalid{errors: errors} = error) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Forbidden{}, &1)) -> {:error, :forbidden}
      Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) -> {:error, :not_found}
      true -> {:error, error}
    end
  end

  defp normalize_read_error(error), do: {:error, error}

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

  defp optional_string(attrs, key) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)) do
      {:present, attrs |> value(key, "") |> to_string()}
    else
      :missing
    end
  end

  defp value(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp ash_opts(nil), do: [authorize?: false]
  defp ash_opts(actor), do: [actor: actor]

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
