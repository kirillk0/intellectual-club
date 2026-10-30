defmodule IntellectualClubWeb.Bff.ChatGenerationFlow do
  @moduledoc """
  BFF orchestration for chat generation endpoints.
  """

  alias IntellectualClub.Chat.Branching
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatDraft
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatForkContext
  alias IntellectualClubWeb.Bff.ChatAttachments
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.ChatPayloads
  alias IntellectualClubWeb.Bff.ChatUploadPolicy
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  @configuration_unavailable "Configuration is invalid or not accessible."

  def send_message(chat_id, params, actor) do
    content = params |> Map.get("content", "") |> to_string()
    explicit_parent? = Map.has_key?(params, "parent_id")
    parent_id = Helpers.parse_optional_integer(Map.get(params, "parent_id"))

    with {:ok, chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
         :ok <- ChatAccess.ensure_append_only(chat, params),
         linked_fork? = ChatForkContext.linked?(chat),
         upload_policy = ChatUploadPolicy.load_for_chat(chat_id, actor),
         {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params),
         :ok <- validate_send_payload(content, prepared_uploads),
         {:ok, context} <-
           prepare_user_generation_with_attachments(
             chat_id,
             actor,
             upload_policy,
             prepared_uploads,
             content,
             if(linked_fork?, do: nil, else: parent_id),
             explicit_parent? and not linked_fork?,
             params["draft_revision"]
           ),
         :ok <- publish_accepted_draft(chat_id, actor, params["draft_revision"]),
         {:ok, context} <- GenerationSupervisor.start_prepared_context(context) do
      {:ok, branch_generation_payload(chat_id, context, actor)}
    end
  end

  defp publish_accepted_draft(chat_id, actor, revision) when is_integer(revision) do
    ChatDraft.publish_current(chat_id, actor)
    :ok
  end

  defp publish_accepted_draft(_chat_id, _actor, _revision), do: :ok

  defp validate_send_payload(content, prepared_uploads) when is_map(prepared_uploads) do
    has_uploads? =
      [:upload_ids, :copy_content_ids, :legacy_uploads]
      |> Enum.any?(fn key -> List.wrap(Map.get(prepared_uploads, key, [])) != [] end)

    if to_string(content || "") != "" or has_uploads? do
      :ok
    else
      {:error, "A user message must contain text or an attachment."}
    end
  end

  def generate(chat_id, params, actor) do
    generation_opts = ChatParams.generation_parent_opts(params, actor)

    with {:ok, chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
         :ok <- ChatAccess.ensure_append_only(chat, params),
         generation_opts =
           if(ChatForkContext.linked?(chat),
             do: Keyword.delete(generation_opts, :parent_id),
             else: generation_opts
           ),
         {:ok, context} <-
           QueueCoordinator.prepare_direct_generation(chat_id, generation_opts),
         {:ok, context} <- GenerationSupervisor.start_prepared_context(context) do
      {:ok, branch_generation_payload(chat_id, context, actor)}
    end
  end

  def branch_to_new_chat(chat_id, message_id, params, actor) when is_integer(message_id) do
    with {:ok, options} <- ChatParams.branch_options(params),
         {:ok, %Chat{} = source} <- ChatAccess.fetch_owned_chat(chat_id, actor),
         :ok <- ChatAccess.ensure_history_mutable(source),
         {:ok, selection} <- Branching.active_branch_selection(source, message_id, actor),
         {:ok, %Chat{} = target} <- create_branch_target_chat(selection, params, options, actor),
         {:ok, context} <- maybe_start_branch_generation(target, options, actor) do
      {:ok,
       %{
         chat:
           Serializer.chat_detail(Ash.load!(target, [:last_message, :read_state], actor: actor)),
         generation: generation_payload(context)
       }}
    end
  end

  def branch_to_new_chat(_chat_id, _message_id, _params, _actor), do: {:error, :message_required}

  @doc """
  Branches from an active-branch message inside the same chat.

  A user message gets a sibling with the submitted contents; an assistant
  message is regenerated from its parent. An optional `llm_configuration_id`
  becomes the chat configuration under the same admission boundary, and
  `start_generation: false` only moves the active branch to the new leaf.
  """
  def branch_in_chat(chat_id, message_id, params, actor) when is_integer(message_id) do
    with {:ok, options} <- ChatParams.branch_options(params),
         {:ok, %Chat{} = chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
         :ok <- ChatAccess.ensure_history_mutable(chat),
         {:ok, selection} <- Branching.active_branch_selection(chat, message_id, actor),
         {:ok, context} <- branch_in_chat_selection(selection, params, options, actor) do
      {messages, branch_meta_by_id} = ChatPayloads.load_branch(chat_id, actor)

      {:ok,
       %{
         branch: ChatPayloads.serialize_branch(messages, branch_meta_by_id, actor),
         chat:
           Serializer.chat_detail(
             Ash.get!(Chat, chat_id, actor: actor, load: [:last_message, :read_state])
           ),
         generation: generation_payload(context)
       }}
    end
  end

  def branch_in_chat(_chat_id, _message_id, _params, _actor), do: {:error, :message_required}

  def manual_handoff(chat_id, actor) do
    with {:ok, context} <-
           QueueCoordinator.prepare_direct_generation(
             chat_id,
             [actor: actor, completion_effect: :manual_handoff],
             fn -> Handoff.prepare_manual_handoff_message(chat_id, actor) end
           ),
         {:ok, context} <- GenerationSupervisor.start_prepared_context(context) do
      {:ok, branch_generation_payload(chat_id, context, actor)}
    end
  end

  defp branch_generation_payload(chat_id, context, actor) do
    {messages, branch_meta_by_id} = ChatPayloads.load_branch(chat_id, actor)

    %{
      branch: ChatPayloads.serialize_branch(messages, branch_meta_by_id, actor),
      generation: %{message_id: context.message_id}
    }
  end

  defp prepare_user_generation_with_attachments(
         chat_id,
         actor,
         upload_policy,
         prepared_uploads,
         content,
         parent_id,
         explicit_parent?,
         draft_revision
       ) do
    ChatAttachments.with_prepared_file_ids(
      chat_id,
      actor,
      upload_policy,
      prepared_uploads,
      fn file_ids ->
        text_contents =
          case to_string(content || "") do
            "" -> []
            text -> [%{kind: :text, content_text: text}]
          end

        media_contents = Enum.map(file_ids, &%{kind: :media, file_id: &1})

        opts =
          if explicit_parent?, do: [actor: actor, parent_id: parent_id], else: [actor: actor]

        QueueCoordinator.prepare_direct_generation(chat_id, opts, fn ->
          with {:ok, message} <-
                 create_user_message(
                   chat_id,
                   text_contents ++ media_contents,
                   parent_id,
                   explicit_parent?,
                   actor
                 ) do
            ChatDraft.consume(chat_id, content, draft_revision, actor)
            {:ok, message}
          end
        end)
      end
    )
  end

  defp create_user_message(chat_id, contents, parent_id, explicit_parent?, actor) do
    params =
      %{
        chat_id: chat_id,
        contents: contents,
        use_active_leaf_parent: not explicit_parent?
      }
      |> maybe_put_parent_id(parent_id, explicit_parent?)

    case ChatMessage
         |> Ash.Changeset.for_create(:add_user_message_with_contents, params, actor: actor)
         |> Ash.create() do
      {:ok, message} -> {:ok, message}
      {:error, error} -> {:error, {:user_message, error}}
    end
  end

  defp maybe_put_parent_id(params, parent_id, true), do: Map.put(params, :parent_id, parent_id)
  defp maybe_put_parent_id(params, _parent_id, _explicit_parent?), do: params

  defp create_branch_target_chat(
         %{source: %Chat{} = source, message: %ChatMessage{} = selected, user_message?: true},
         params,
         options,
         actor
       ) do
    create_user_branch_target_chat(source, selected, params, options, actor)
  end

  defp create_branch_target_chat(
         %{source: %Chat{} = source, message: %ChatMessage{} = selected},
         _params,
         options,
         actor
       ) do
    create_branch_target_via_ash(source.id, selected.id, actor,
      llm_configuration_id: options.llm_configuration_id
    )
  end

  defp create_user_branch_target_chat(
         %Chat{} = source,
         %ChatMessage{} = selected,
         params,
         options,
         actor
       ) do
    with_branch_user_contents(source.id, options, params, actor, fn contents ->
      create_branch_target_via_ash(source.id, selected.id, actor,
        replacement_contents: contents,
        llm_configuration_id: options.llm_configuration_id
      )
    end)
  end

  # New files of a branch message are validated against the configuration the
  # branch will use, not the configuration of the chat it branches from.
  defp with_branch_user_contents(chat_id, options, params, actor, fun)
       when is_function(fun, 1) do
    with {:ok, upload_policy} <- branch_upload_policy(chat_id, options, actor),
         {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params) do
      ChatAttachments.with_prepared_file_ids(
        chat_id,
        actor,
        upload_policy,
        prepared_uploads,
        fn file_ids ->
          case ChatParams.branch_user_replacement_contents(params, file_ids) do
            [] -> {:error, :empty_user_message}
            contents -> fun.(contents)
          end
        end
      )
    end
  end

  defp branch_in_chat_selection(
         %{source: %Chat{} = chat, message: %ChatMessage{} = selected, user_message?: true},
         params,
         options,
         actor
       ) do
    prepared =
      with_branch_user_contents(chat.id, options, params, actor, fn contents ->
        mutation = fn ->
          with :ok <- apply_configuration_override(chat.id, options.llm_configuration_id, actor) do
            create_user_message(chat.id, contents, selected.parent_id, true, actor)
          end
        end

        if options.start_generation? do
          QueueCoordinator.prepare_direct_generation(
            chat.id,
            [actor: actor, parent_id: selected.parent_id],
            mutation
          )
        else
          QueueCoordinator.run_direct_mutation(chat.id, actor, fn ->
            with {:ok, _message} <- mutation.(), do: {:ok, nil}
          end)
        end
      end)

    case prepared do
      {:ok, nil} -> {:ok, nil}
      {:ok, context} -> GenerationSupervisor.start_prepared_context(context)
      {:error, _reason} = error -> error
    end
  end

  defp branch_in_chat_selection(
         %{source: %Chat{} = chat, message: %ChatMessage{} = selected},
         _params,
         %{start_generation?: true} = options,
         actor
       ) do
    # Without an override the regular out-of-lock preparation path stays available.
    prepare_parent =
      case options.llm_configuration_id do
        nil ->
          nil

        configuration_id ->
          fn ->
            with :ok <- apply_configuration_override(chat.id, configuration_id, actor),
                 do: {:ok, []}
          end
      end

    with {:ok, context} <-
           QueueCoordinator.prepare_direct_generation(
             chat.id,
             [actor: actor, parent_id: selected.parent_id],
             prepare_parent
           ) do
      GenerationSupervisor.start_prepared_context(context)
    end
  end

  defp branch_in_chat_selection(
         %{source: %Chat{} = chat, message: %ChatMessage{} = selected},
         _params,
         options,
         actor
       ) do
    QueueCoordinator.run_direct_mutation(chat.id, actor, fn ->
      with :ok <- apply_configuration_override(chat.id, options.llm_configuration_id, actor),
           {:ok, _chat} <- set_active_leaf(chat.id, selected.parent_id, actor) do
        {:ok, nil}
      end
    end)
  end

  defp branch_upload_policy(chat_id, %{llm_configuration_id: configuration_id}, actor) do
    case ChatUploadPolicy.load_for_chat_configuration(chat_id, configuration_id, actor) do
      {:ok, policy} -> {:ok, policy}
      {:error, :llm_configuration_not_accessible} -> {:error, @configuration_unavailable}
    end
  end

  defp apply_configuration_override(_chat_id, nil, _actor), do: :ok

  # Runs inside the admission transaction. Readability is checked up front
  # because a failed nested Ash update would abort the whole transaction with
  # its own error instead of returning a recoverable result.
  defp apply_configuration_override(chat_id, configuration_id, actor)
       when is_integer(configuration_id) do
    with {:ok, %Chat{} = chat} <- Ash.get(Chat, chat_id, actor: actor) do
      cond do
        chat.llm_configuration_id == configuration_id ->
          :ok

        not readable_configuration?(configuration_id, actor) ->
          {:error, @configuration_unavailable}

        true ->
          chat
          |> Ash.Changeset.for_update(:update, %{llm_configuration_id: configuration_id},
            actor: actor
          )
          |> Ash.update()
          |> case do
            {:ok, _chat} -> :ok
            {:error, _reason} = error -> error
          end
      end
    end
  end

  defp readable_configuration?(configuration_id, actor) do
    match?(
      {:ok, %LlmConfiguration{id: ^configuration_id}},
      Ash.get(LlmConfiguration, configuration_id, actor: actor)
    )
  end

  defp set_active_leaf(chat_id, leaf_id, actor) do
    Chat
    |> Ash.get!(chat_id, actor: actor)
    |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: leaf_id}, actor: actor)
    |> Ash.update()
  end

  defp generation_payload(nil), do: nil
  defp generation_payload(%{message_id: message_id}), do: %{message_id: message_id}

  defp create_branch_target_via_ash(source_chat_id, message_id, actor, opts) do
    replacement_contents = Keyword.get(opts, :replacement_contents)

    params =
      %{
        id: source_chat_id,
        message_id: message_id
      }
      |> maybe_put_replacement_contents(replacement_contents)
      |> maybe_put_configuration_override(Keyword.get(opts, :llm_configuration_id))

    Chat
    |> Ash.Changeset.for_create(:create_branch, params, actor: actor)
    |> Ash.create()
  end

  defp maybe_put_replacement_contents(params, nil), do: params

  defp maybe_put_replacement_contents(params, contents),
    do: Map.put(params, :replacement_contents, contents)

  defp maybe_put_configuration_override(params, nil), do: params

  defp maybe_put_configuration_override(params, configuration_id),
    do: Map.put(params, :llm_configuration_id, configuration_id)

  defp maybe_start_branch_generation(_target, %{start_generation?: false}, _actor),
    do: {:ok, nil}

  defp maybe_start_branch_generation(%Chat{} = target, _options, actor),
    do: start_branch_generation(target, actor)

  defp start_branch_generation(%Chat{} = target, actor) do
    try do
      case GenerationSupervisor.start_generation(target.id, actor: actor) do
        {:ok, context} ->
          {:ok, context}

        {:error, reason} ->
          cleanup_branch_target_chat(target, actor)
          {:error, "Failed to start generation: #{inspect(reason)}"}
      end
    rescue
      error ->
        cleanup_branch_target_chat(target, actor)
        {:error, "Failed to start generation: #{Exception.message(error)}"}
    catch
      kind, reason ->
        cleanup_branch_target_chat(target, actor)
        {:error, "Failed to start generation: #{kind}: #{inspect(reason)}"}
    end
  end

  defp cleanup_branch_target_chat(%Chat{} = target, actor) do
    _ = Ash.destroy(target, actor: actor)
    :ok
  end
end
