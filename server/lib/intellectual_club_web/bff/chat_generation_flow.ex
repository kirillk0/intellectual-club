defmodule IntellectualClubWeb.Bff.ChatGenerationFlow do
  @moduledoc """
  BFF orchestration for chat generation endpoints.
  """

  alias IntellectualClub.Chat.Branching
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatAttachments
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.ChatPayloads
  alias IntellectualClubWeb.Bff.ChatUploadPolicy
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  def send_message(chat_id, params, actor) do
    content = params |> Map.get("content", "") |> to_string()
    explicit_parent? = Map.has_key?(params, "parent_id")
    parent_id = Helpers.parse_optional_integer(Map.get(params, "parent_id"))

    with {:ok, _chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
         upload_policy = ChatUploadPolicy.load_for_chat(chat_id, actor),
         {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params),
         {:ok, :ok} <-
           create_user_message_with_prepared_attachments(
             chat_id,
             actor,
             upload_policy,
             prepared_uploads,
             content,
             parent_id,
             explicit_parent?
           ),
         {:ok, context} <- GenerationSupervisor.start_generation(chat_id, actor: actor) do
      {:ok, branch_generation_payload(chat_id, context, actor)}
    end
  end

  def generate(chat_id, params, actor) do
    generation_opts = ChatParams.generation_parent_opts(params, actor)

    with {:ok, _chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
         {:ok, context} <- GenerationSupervisor.start_generation(chat_id, generation_opts) do
      {:ok, branch_generation_payload(chat_id, context, actor)}
    end
  end

  def branch_to_new_chat(chat_id, message_id, params, actor) when is_integer(message_id) do
    with {:ok, %Chat{} = source} <- ChatAccess.fetch_owned_chat(chat_id, actor),
         {:ok, selection} <- Branching.active_branch_selection(source, message_id, actor),
         {:ok, %Chat{} = target} <- create_branch_target_chat(selection, params, actor),
         {:ok, context} <- start_branch_generation(target, actor) do
      {messages, branch_meta_by_id} = ChatPayloads.load_branch(target.id, actor)

      {:ok,
       %{
         chat: Serializer.chat_detail(target),
         branch: ChatPayloads.serialize_branch(messages, branch_meta_by_id, actor),
         generation: %{message_id: context.message_id}
       }}
    end
  end

  def branch_to_new_chat(_chat_id, _message_id, _params, _actor), do: {:error, :message_required}

  def manual_handoff(chat_id, actor) do
    with {:ok, prompt_message} <- Handoff.prepare_manual_handoff_message(chat_id, actor),
         {:ok, context} <-
           GenerationSupervisor.start_generation(chat_id,
             actor: actor,
             parent_id: prompt_message.id,
             tools_payload_override: [],
             completion_effect: :manual_handoff
           ) do
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

  defp create_user_message_with_prepared_attachments(
         chat_id,
         actor,
         upload_policy,
         prepared_uploads,
         content,
         parent_id,
         explicit_parent?
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

        maybe_create_user_message(
          chat_id,
          text_contents ++ media_contents,
          parent_id,
          explicit_parent?,
          actor
        )
        |> case do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp maybe_create_user_message(chat_id, contents, parent_id, explicit_parent?, actor) do
    if contents == [] do
      :ok
    else
      params =
        %{
          chat_id: chat_id,
          contents: contents,
          use_active_leaf_parent: not explicit_parent?
        }
        |> maybe_put_parent_id(parent_id, explicit_parent?)

      with {:ok, _message} <-
             ChatMessage
             |> Ash.Changeset.for_create(:add_user_message_with_contents, params, actor: actor)
             |> Ash.create() do
        :ok
      else
        {:error, error} ->
          {:error, {:user_message, error}}
      end
    end
  end

  defp maybe_put_parent_id(params, parent_id, true), do: Map.put(params, :parent_id, parent_id)
  defp maybe_put_parent_id(params, _parent_id, _explicit_parent?), do: params

  defp create_branch_target_chat(
         %{source: %Chat{} = source, message: %ChatMessage{} = selected, user_message?: true},
         params,
         actor
       ) do
    create_user_branch_target_chat(source, selected, params, actor)
  end

  defp create_branch_target_chat(
         %{source: %Chat{} = source, message: %ChatMessage{} = selected},
         _params,
         actor
       ) do
    create_branch_target_via_ash(source.id, selected.id, actor)
  end

  defp create_user_branch_target_chat(%Chat{} = source, %ChatMessage{} = selected, params, actor) do
    upload_policy = ChatUploadPolicy.load_for_chat(source.id, actor)

    with {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params) do
      ChatAttachments.with_prepared_file_ids(
        source.id,
        actor,
        upload_policy,
        prepared_uploads,
        fn file_ids ->
          contents = ChatParams.branch_user_replacement_contents(params, file_ids)

          if contents == [] do
            {:error, :empty_user_message}
          else
            create_branch_target_via_ash(source.id, selected.id, actor,
              replacement_contents: contents
            )
          end
        end
      )
    end
  end

  defp create_branch_target_via_ash(source_chat_id, message_id, actor, opts \\ []) do
    replacement_contents = Keyword.get(opts, :replacement_contents)

    params =
      %{
        id: source_chat_id,
        message_id: message_id
      }
      |> maybe_put_replacement_contents(replacement_contents)

    Chat
    |> Ash.Changeset.for_create(:create_branch, params, actor: actor)
    |> Ash.create()
  end

  defp maybe_put_replacement_contents(params, nil), do: params

  defp maybe_put_replacement_contents(params, contents),
    do: Map.put(params, :replacement_contents, contents)

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
