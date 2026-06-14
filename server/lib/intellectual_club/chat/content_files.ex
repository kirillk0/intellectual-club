defmodule IntellectualClub.Chat.ContentFiles do
  @moduledoc """
  Helpers for loading file payloads referenced by chat message contents.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
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

  defp load_available_file_payload(normalized_external_id, %ExecutionContext{} = context) do
    if available_file_external_id?(normalized_external_id, context) do
      with {:ok, {file, payload}} <- Files.load_payload_by_external_id(normalized_external_id) do
        {:ok, {nil, file, payload}}
      end
    else
      {:error, :not_found}
    end
  end

  defp find_content_for_file(normalized_external_id, %ExecutionContext{} = context)
       when is_binary(normalized_external_id) do
    chat_ids = handoff_chat_scope_ids(context)

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
      {:ok, %ChatMessageContent{} = content} -> {:ok, content}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp handoff_chat_scope_ids(%ExecutionContext{chat_id: chat_id, owner_id: owner_id})
       when is_integer(chat_id) and is_integer(owner_id) do
    chat_id
    |> collect_handoff_chat_scope_ids(owner_id, MapSet.new(), [])
    |> case do
      [] -> [chat_id]
      ids -> ids
    end
  end

  defp handoff_chat_scope_ids(%ExecutionContext{chat_id: chat_id}) when is_integer(chat_id),
    do: [chat_id]

  defp handoff_chat_scope_ids(_context), do: []

  defp collect_handoff_chat_scope_ids(chat_id, owner_id, seen, acc)
       when is_integer(chat_id) and is_integer(owner_id) do
    if MapSet.member?(seen, chat_id) do
      Enum.reverse(acc)
    else
      seen = MapSet.put(seen, chat_id)

      case load_owned_chat_for_scope(chat_id, owner_id) do
        {:ok, %Chat{} = chat} ->
          acc = [chat.id | acc]

          if handoff_child?(chat) and is_integer(chat.parent_chat_id) do
            collect_handoff_chat_scope_ids(chat.parent_chat_id, owner_id, seen, acc)
          else
            Enum.reverse(acc)
          end

        _other ->
          Enum.reverse(acc)
      end
    end
  end

  defp load_owned_chat_for_scope(chat_id, owner_id) do
    Chat
    |> Ash.Query.filter(id == ^chat_id and owner_id == ^owner_id)
    |> Ash.Query.select([:id, :owner_id, :parent_chat_id, :parent_relation_kind])
    |> Ash.read_one(authorize?: false)
  end

  defp handoff_child?(%Chat{parent_relation_kind: value}), do: value in [:handoff, "handoff"]

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
