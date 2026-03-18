defmodule IntellectualClub.Chat.ContentFiles do
  @moduledoc """
  Helpers for loading file payloads referenced by chat message contents.
  """

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Db
  alias IntellectualClub.Files
  alias IntellectualClub.Tools.ExecutionContext

  @spec load_payload_for_content(ChatMessageContent.t()) ::
          {:ok, {ChatMessageContent.t(), map(), binary()}} | {:error, term()}
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
          {:ok, {map(), map(), binary()}} | {:error, term()}
  def load_payload_for_execution(content_external_id, %ExecutionContext{} = context)
      when is_binary(content_external_id) do
    with {:ok, normalized_external_id} <- normalize_external_id(content_external_id) do
      repo = Db.repo()

      content =
        repo.one(
          from(c in "chat_message_contents",
            join: i in "chat_message_items",
            on: i.id == c.chat_message_item_id,
            join: s in "chat_message_steps",
            on: s.id == i.chat_message_step_id,
            join: m in "chat_messages",
            on: m.id == s.chat_message_id,
            join: f in "files",
            on: f.id == c.file_id,
            where:
              c.external_id == ^normalized_external_id and c.kind == "media" and
                c.owner_id == ^context.owner_id and m.owner_id == ^context.owner_id and
                m.chat_id == ^context.chat_id,
            select: %{
              content: %{
                id: c.id,
                external_id: c.external_id,
                file_id: c.file_id,
                sequence: c.sequence,
                kind: c.kind
              },
              file: %{
                id: f.id,
                external_id: f.external_id,
                filename: f.filename,
                mime_type: f.mime_type,
                size_bytes: f.size_bytes,
                sha256: f.sha256
              }
            }
          )
        )

      with %{content: content, file: file} <- content,
           {:ok, {_stored_file, payload}} <- Files.load_payload(file.id) do
        {:ok, {content, file, payload}}
      else
        nil -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  def load_payload_for_execution(_content_external_id, _context), do: {:error, :invalid_request}

  defp normalize_external_id(value) when is_binary(value) do
    value = String.trim(value)

    with {:ok, canonical_uuid} <- Ecto.UUID.cast(value) do
      case Db.adapter() do
        :sqlite -> {:ok, canonical_uuid}
        :postgres -> Ecto.UUID.dump(canonical_uuid)
      end
    else
      :error -> {:error, :invalid_request}
    end
  end
end
