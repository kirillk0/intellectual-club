defmodule IntellectualClub.Chat.ContentFiles do
  @moduledoc """
  Helpers for loading file payloads referenced by chat message contents.
  """

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
          {:ok, {ChatMessageContent.t(), StoredFile.t(), binary()}} | {:error, term()}
  def load_payload_for_execution(file_external_id, %ExecutionContext{} = context)
      when is_binary(file_external_id) do
    with {:ok, normalized_external_id} <- normalize_external_id(file_external_id),
         {:ok, %ChatMessageContent{} = content} <-
           find_content_for_file(normalized_external_id, context),
         %StoredFile{} = file <- Map.get(content, :file),
         {:ok, {_stored_file, payload}} <- Files.load_payload(file.id) do
      {:ok, {content, file, payload}}
    else
      nil -> {:error, :file_not_found}
      {:error, error} -> {:error, error}
    end
  end

  def load_payload_for_execution(_file_external_id, _context), do: {:error, :invalid_request}

  defp find_content_for_file(normalized_external_id, %ExecutionContext{} = context)
       when is_binary(normalized_external_id) do
    ChatMessageContent
    |> Ash.Query.filter(
      kind == :media and owner_id == ^context.owner_id and
        exists(file, external_id == ^normalized_external_id) and
        exists(
          chat_message_item.chat_message_step.chat_message,
          owner_id == ^context.owner_id and chat_id == ^context.chat_id
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

  defp normalize_external_id(value) when is_binary(value) do
    value = String.trim(value)

    case Ecto.UUID.cast(value) do
      {:ok, canonical_uuid} -> {:ok, canonical_uuid}
      :error -> {:error, :invalid_request}
    end
  end
end
