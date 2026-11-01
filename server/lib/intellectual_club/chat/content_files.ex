defmodule IntellectualClub.Chat.ContentFiles do
  @moduledoc """
  Helpers for loading file payloads referenced by chat message contents.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ForkHistory
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Tools.ExecutionContext

  require Ash.Query

  @spec load_payload_for_content(ChatMessageContent.t()) ::
          {:ok, {ChatMessageContent.t(), StoredFile.t(), binary()}} | {:error, term()}
  def load_payload_for_content(%ChatMessageContent{} = content) do
    if is_integer(content.file_id) do
      with {:ok, {file, payload}} <- Files.load_payload(content.file_id) do
        {:ok, {content, file, payload}}
      end
    else
      {:error, :file_not_found}
    end
  end

  @spec load_path_for_content(ChatMessageContent.t()) ::
          {:ok, {ChatMessageContent.t(), StoredFile.t(), String.t()}} | {:error, term()}
  def load_path_for_content(%ChatMessageContent{} = content) do
    if is_integer(content.file_id) do
      with {:ok, {file, path}} <- Files.load_path(content.file_id) do
        {:ok, {content, file, path}}
      end
    else
      {:error, :file_not_found}
    end
  end

  @spec load_payload_for_execution(String.t(), ExecutionContext.t()) ::
          {:ok, {ChatMessageContent.t() | nil, StoredFile.t(), binary()}} | {:error, term()}
  def load_payload_for_execution(file_external_id, %ExecutionContext{} = context)
      when is_binary(file_external_id) do
    with {:ok, normalized_external_id} <- normalize_external_id(file_external_id) do
      case load_chat_content_payload(normalized_external_id, context) do
        {:ok, {_content, _file, _payload}} = ok -> ok
        {:error, :not_found} -> load_available_file_payload(normalized_external_id, context)
        {:error, error} -> {:error, error}
      end
    end
  end

  def load_payload_for_execution(_file_external_id, _context), do: {:error, :invalid_request}

  @spec load_path_for_execution(String.t(), ExecutionContext.t()) ::
          {:ok, {ChatMessageContent.t() | nil, StoredFile.t(), String.t()}} | {:error, term()}
  def load_path_for_execution(file_external_id, %ExecutionContext{} = context)
      when is_binary(file_external_id) do
    with {:ok, normalized_external_id} <- normalize_external_id(file_external_id) do
      case load_chat_content_path(normalized_external_id, context) do
        {:ok, {_content, _file, _path}} = ok -> ok
        {:error, :not_found} -> load_available_file_path(normalized_external_id, context)
        {:error, error} -> {:error, error}
      end
    end
  end

  def load_path_for_execution(_file_external_id, _context), do: {:error, :invalid_request}

  defp load_chat_content_payload(normalized_external_id, %ExecutionContext{} = context) do
    with {:ok, %ChatMessageContent{} = content} <-
           find_content_for_file(normalized_external_id, context),
         %StoredFile{} = file <- Map.get(content, :file),
         {:ok, {_stored_file, payload}} <- Files.load_payload(file.id) do
      {:ok, {content, file, payload}}
    else
      nil -> {:error, :file_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp load_chat_content_path(normalized_external_id, %ExecutionContext{} = context) do
    with {:ok, %ChatMessageContent{} = content} <-
           find_content_for_file(normalized_external_id, context),
         %StoredFile{} = file <- Map.get(content, :file),
         {:ok, {_stored_file, path}} <- Files.load_path(file.id) do
      {:ok, {content, file, path}}
    else
      nil -> {:error, :file_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp load_available_file_payload(normalized_external_id, %ExecutionContext{} = context) do
    if available_file_external_id?(normalized_external_id, context) do
      with {:ok, {file, payload}} <- Files.load_payload_by_external_id(normalized_external_id) do
        {:ok, {nil, file, payload}}
      end
    else
      {:error, :not_found}
    end
  end

  defp load_available_file_path(normalized_external_id, %ExecutionContext{} = context) do
    if available_file_external_id?(normalized_external_id, context) do
      with {:ok, {file, path}} <- Files.load_path_by_external_id(normalized_external_id) do
        {:ok, {nil, file, path}}
      end
    else
      {:error, :not_found}
    end
  end

  defp find_content_for_file(normalized_external_id, %ExecutionContext{} = context)
       when is_binary(normalized_external_id) and is_integer(context.chat_id) and
              is_integer(context.owner_id) do
    chat_ids = List.wrap(context.chat_id)

    ChatMessageContent
    |> Ash.Query.filter(
      kind == :media and owner_id == ^context.owner_id and
        exists(file, external_id == ^normalized_external_id) and
        exists(
          chat_message_item.chat_message_step.chat_message,
          owner_id == ^context.owner_id and chat_id in ^chat_ids
        )
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, load: [:file])
    |> case do
      {:ok, %ChatMessageContent{} = content} ->
        {:ok, content}

      {:ok, nil} ->
        find_inherited_content_for_file(normalized_external_id, chat_ids, context.owner_id)

      {:error, error} ->
        {:error, error}
    end
  end

  defp find_content_for_file(_external_id, _context), do: {:error, :not_found}

  defp find_inherited_content_for_file(normalized_external_id, chat_ids, owner_id)
       when is_integer(owner_id) do
    actor = %{id: owner_id}

    # A fork grants access only to its projected prefix, never to an entire
    # source chat or its request-file bindings.
    with {:ok, forks} <-
           Chat
           |> Ash.Query.filter(
             id in ^chat_ids and owner_id == ^owner_id and not is_nil(fork_source_step_id)
           )
           |> Ash.Query.select([:id])
           |> Ash.read(actor: actor) do
      Enum.reduce_while(forks, {:error, :not_found}, fn fork, not_found ->
        case ForkHistory.prefix(fork.id, actor) do
          {:ok, messages} ->
            case inherited_content(messages, normalized_external_id, owner_id) do
              %ChatMessageContent{} = content -> {:halt, {:ok, content}}
              nil -> {:cont, not_found}
            end

          {:error, :fork_context_unavailable} ->
            {:cont, not_found}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp inherited_content(messages, normalized_external_id, owner_id) do
    # File tools remain owner-scoped even if a history reader can see shared chats.
    # Synthetic boundary results contain no media, so only actual prefix contents
    # can grant access; later results, artifacts, steps and sibling branches cannot.
    if Enum.all?(messages, &(Map.get(&1, :owner_id) == owner_id)) do
      messages
      |> Stream.flat_map(&History.steps/1)
      |> Stream.flat_map(&History.items/1)
      |> Stream.flat_map(&History.contents/1)
      |> Enum.find(fn
        %ChatMessageContent{
          kind: :media,
          owner_id: ^owner_id,
          file: %StoredFile{external_id: external_id}
        } ->
          to_string(external_id) == normalized_external_id

        _content ->
          false
      end)
    end
  end

  defp normalize_external_id(value) when is_binary(value) do
    value = String.trim(value)

    case Ecto.UUID.cast(value) do
      {:ok, canonical_uuid} -> {:ok, canonical_uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp available_file_external_id?(normalized_external_id, %ExecutionContext{} = context)
       when is_binary(normalized_external_id) do
    context
    |> Map.get(:available_file_external_ids, [])
    |> normalize_available_file_external_ids()
    |> MapSet.member?(normalized_external_id)
  end

  defp normalize_available_file_external_ids(%MapSet{} = ids), do: ids

  defp normalize_available_file_external_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_available_file_external_ids(_ids), do: MapSet.new()
end
