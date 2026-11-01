defmodule IntellectualClub.Chat.Handoff do
  @moduledoc """
  Builds and publishes context checkpoints within the current chat.
  """

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.HandoffRolloff
  alias IntellectualClub.Chat.Handoff.CheckpointRollback
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Knowledge.KnowledgeBlock

  require Ash.Query

  @summary_request """
  You are preparing a handoff summary so work can continue with compact context in the same chat.

  Summarize only the useful current state. Include:
  - the user's goal and current task,
  - completed work and decisions,
  - important constraints and assumptions,
  - files, commands, tools, APIs, or data that matter,
  - current status, blockers, and exact next steps.

  Write the summary as a clear continuation prompt for the next assistant.
  Do not answer the original user request directly. Do not mention that you are compacting context.

  Create the handoff summary now.
  """

  @spec manual_handoff(integer(), map()) :: {:ok, map()} | {:error, term()}
  def manual_handoff(source_chat_id, actor) when is_integer(source_chat_id) do
    with {:ok, context} <-
           QueueCoordinator.prepare_direct_generation(
             source_chat_id,
             [actor: actor, completion_effect: :manual_handoff],
             fn -> prepare_manual_handoff_message(source_chat_id, actor) end
           ) do
      GenerationSupervisor.start_prepared_context(context)
    end
  end

  def manual_handoff(_source_chat_id, _actor), do: {:error, :invalid_chat_id}

  @spec prepare_manual_handoff_message(integer(), map()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def prepare_manual_handoff_message(source_chat_id, actor) when is_integer(source_chat_id) do
    with {:ok, %Chat{} = source} <- fetch_owned_chat(source_chat_id, actor),
         {:ok, handoff_prompt} <- handoff_prompt(source, actor),
         {:ok, prompt_message} <-
           Threads.add_message(source, :user, handoff_prompt,
             actor: actor,
             parent_id: source.last_message_id,
             item_type: :handoff_request,
             status: :done
           ) do
      {:ok, prompt_message}
    end
  end

  def prepare_manual_handoff_message(_source_chat_id, _actor), do: {:error, :invalid_chat_id}

  @doc "Builds a checkpoint from the original branch, including completed work in a running message."
  @spec prepare_compaction(integer(), map(), String.t()) ::
          {:ok, HandoffRolloff.result()} | {:error, term()}
  def prepare_compaction(message_id, actor, summary) when is_integer(message_id) do
    with {:ok, message} <- fetch_compaction_message(message_id, actor),
         {:ok, source} <- fetch_owned_chat(message.chat_id, actor),
         {:ok, summary} <- normalize_summary(summary) do
      HandoffRolloff.build(source, actor, summary, source_message_id: message.id)
    end
  end

  def prepare_compaction(_message_id, _actor, _summary), do: {:error, :invalid_message_id}

  @doc "Publishes checkpoint files together with the caller's durable step transition."
  def with_compaction_items(rolloff, fun) when is_map(rolloff) and is_function(fun, 1) do
    case IntellectualClub.Generation.PersistenceFailure.ash_transaction([Chat], fn ->
           with {:ok, items} <- rolloff_item_specs(rolloff) do
             items =
               items
               |> Enum.with_index(1)
               |> Enum.map(fn {item, sequence} ->
                 contents =
                   item.contents
                   |> Enum.with_index(1)
                   |> Enum.map(fn {content, content_sequence} ->
                     content
                     |> Map.put(:sequence, content_sequence)
                     |> Map.put_new(:external_id, Ash.UUID.generate())
                   end)

                 Map.merge(item, %{sequence: sequence, contents: contents})
               end)

             case fun.(items) do
               {:error, reason} -> raise CheckpointRollback, reason: reason
               result -> result
             end
           else
             {:error, reason} -> raise CheckpointRollback, reason: reason
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in CheckpointRollback -> {:error, error.reason}
  end

  @spec complete_manual_generation(integer(), map()) :: {:ok, map()} | {:error, term()}
  def complete_manual_generation(message_id, actor) when is_integer(message_id) do
    with {:ok, %ChatMessage{} = message} <- fetch_handoff_summary_message(message_id, actor),
         {:ok, summary} <- summary_from_message(message),
         {:ok, source} <- fetch_owned_chat(message.chat_id, actor) do
      Ash.transact(Chat, fn ->
        source =
          Chat
          |> Ash.Query.filter(id == ^source.id)
          |> Ash.Query.lock("FOR NO KEY UPDATE")
          |> Ash.read_one!(actor: actor)

        case existing_manual_checkpoint(message.id, actor) do
          %ChatMessage{} = checkpoint ->
            %{chat: source, message: checkpoint, generation: nil}

          nil ->
            append_manual_checkpoint!(source, message, summary, actor)
        end
      end)
    end
  end

  def complete_manual_generation(_message_id, _actor), do: {:error, :invalid_message_id}

  defp existing_manual_checkpoint(message_id, actor) do
    ChatMessage
    |> Ash.Query.filter(
      parent_id == ^message_id and role == :user and
        exists(steps.items, type == :handoff_message)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: actor)
  end

  defp append_manual_checkpoint!(source, message, summary, actor) do
    with {:ok, rolloff} <-
           HandoffRolloff.build(source, actor, summary,
             source_message_id: message.id,
             exclude_message_ids: [message.id, message.parent_id]
           ),
         {:ok, items} <- rolloff_item_specs(rolloff),
         {:ok, checkpoint} <-
           Threads.add_message_with_items(source, :user, items,
             actor: actor,
             parent_id: message.id,
             status: :done,
             token_count: rolloff.token_count
           ) do
      # Completing a background branch must not steal the selected branch.
      if source.last_message_id != message.id do
        Chat
        |> Ash.get!(source.id, actor: actor)
        |> Ash.Changeset.for_update(
          :set_last_message,
          %{last_message_id: source.last_message_id},
          actor: actor
        )
        |> Ash.update!()
      end

      %{chat: Ash.get!(Chat, source.id, actor: actor), message: checkpoint, generation: nil}
    else
      {:error, reason} -> Ash.DataLayer.rollback(Chat, reason)
    end
  end

  def summary_request, do: @summary_request

  defp rolloff_item_specs(%{history: history, handoff_message: handoff_message} = rolloff)
       when is_list(history) and is_binary(handoff_message) do
    with {:ok, artifact_content} <- rolloff_artifact_content(Map.get(rolloff, :artifact)) do
      history_contents = Enum.map(history, &history_content_spec/1)

      {:ok,
       [
         %{
           type: :handoff_history,
           contents: history_contents ++ List.wrap(artifact_content)
         },
         %{
           type: :handoff_message,
           contents: [%{kind: :text, content_text: handoff_message}]
         }
       ]}
    end
  end

  defp rolloff_item_specs(_rolloff), do: {:error, :invalid_rolloff}

  defp rolloff_artifact_content(nil), do: {:ok, nil}

  defp rolloff_artifact_content(artifact) when is_map(artifact) do
    with {:ok, file} <-
           Files.create_from_binary(
             Map.fetch!(artifact, :filename),
             Map.fetch!(artifact, :mime_type),
             Map.fetch!(artifact, :payload)
           ) do
      {:ok, %{kind: :media, file_id: file.id, file: file}}
    end
  end

  defp rolloff_artifact_content(_artifact), do: {:error, :invalid_rolloff_artifact}

  defp history_content_spec(entry) when is_map(entry) do
    %{
      kind: :text,
      content_text: to_string(Map.get(entry, :text) || ""),
      content_json: history_entry_metadata(entry)
    }
  end

  defp history_entry_metadata(entry) when is_map(entry) do
    %{}
    |> Map.put("entry_kind", entry |> Map.get(:kind, :message) |> to_string())
    |> maybe_put_metadata("role", metadata_role(Map.get(entry, :role)))
    |> maybe_put_metadata("created_at", metadata_datetime(Map.get(entry, :timestamp)))
    |> maybe_put_metadata("omitted_count", Map.get(entry, :omitted_count))
  end

  defp metadata_role(role) when role in [:user, :assistant], do: Atom.to_string(role)
  defp metadata_role(_role), do: nil

  defp metadata_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp metadata_datetime(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp metadata_datetime(value) when is_binary(value), do: value
  defp metadata_datetime(_value), do: nil

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp handoff_prompt(%Chat{} = source, actor) do
    case Ash.load(source, [bot: [:handoff_message_block]], actor: actor) do
      {:ok, %Chat{bot: %Bot{handoff_message_block: %KnowledgeBlock{content: content}}}} ->
        {:ok, to_string(content || "")}

      {:ok, %Chat{}} ->
        {:ok, @summary_request}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, :forbidden}

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_owned_chat(chat_id, %{id: actor_id} = actor)
       when is_integer(chat_id) and is_integer(actor_id) do
    Chat
    |> Ash.Query.filter(id == ^chat_id and owner_id == ^actor_id)
    |> Ash.Query.limit(1)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> {:ok, chat}
      {:ok, []} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_owned_chat(_chat_id, _actor), do: {:error, :invalid_chat_id}

  defp fetch_compaction_message(message_id, %{id: actor_id} = actor)
       when is_integer(actor_id) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id and role == :assistant and owner_id == ^actor_id)
    |> Ash.Query.select([:id, :chat_id])
    |> Ash.read_one(actor: actor, authorize?: true)
    |> case do
      {:ok, %ChatMessage{} = message} -> {:ok, message}
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_compaction_message(_message_id, _actor), do: {:error, :forbidden}

  defp fetch_handoff_summary_message(message_id, actor) when is_integer(message_id) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id and role == :assistant)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(steps: [items: [:contents]])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%ChatMessage{} = message]} -> {:ok, message}
      {:ok, []} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_summary(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> {:error, :empty_summary}
      text -> {:ok, text}
    end
  end

  defp normalize_summary(_summary), do: {:error, :invalid_summary}

  defp summary_from_message(%ChatMessage{} = message) do
    summary =
      message
      |> History.project_text_for_item_type(:handoff_summary)
      |> case do
        value when is_binary(value) and value != "" -> value
        _other -> History.project_text_for_item_type(message, :answer)
      end

    normalize_summary(summary)
  end
end
