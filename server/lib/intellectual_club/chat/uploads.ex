defmodule IntellectualClub.Chat.Uploads do
  @moduledoc """
  Chunked upload sessions for chat attachments.
  """

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Chat.ChatUploadSession
  alias IntellectualClub.Chat.UploadPolicy
  alias IntellectualClub.Db
  alias IntellectualClub.Files

  require Ash.Query

  @default_chunk_size_bytes 5 * 1024 * 1024
  @default_ttl_seconds 24 * 60 * 60
  @upload_root Path.expand("../../../../assets/chat-uploads", __DIR__)

  @type materialized_uploads :: %{
          sessions: [ChatUploadSession.t()],
          files: [IntellectualClub.Files.File.t()]
        }

  @spec default_chunk_size_bytes() :: pos_integer()
  def default_chunk_size_bytes, do: @default_chunk_size_bytes

  @spec start_upload(integer(), term(), map()) ::
          {:ok, ChatUploadSession.t()} | {:error, String.t() | term()}
  def start_upload(chat_id, actor, attrs) when is_integer(chat_id) and is_map(attrs) do
    cleanup_stale_uploads!()

    filename =
      attrs
      |> Map.get("filename", Map.get(attrs, :filename, ""))
      |> to_string()
      |> String.trim()

    mime_type =
      attrs
      |> Map.get("mime_type", Map.get(attrs, :mime_type, "application/octet-stream"))
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "application/octet-stream"
        value -> value
      end

    size_bytes =
      attrs
      |> Map.get("size_bytes", Map.get(attrs, :size_bytes))
      |> normalize_integer()

    policy = UploadPolicy.load_for_chat(chat_id, actor)

    with size when is_integer(size) and size > 0 <- size_bytes,
         :ok <- UploadPolicy.validate_file_spec(filename, mime_type, size, policy),
         :ok <- ensure_upload_root() do
      expires_at = DateTime.add(DateTime.utc_now(), @default_ttl_seconds, :second)

      ChatUploadSession
      |> Ash.Changeset.for_create(
        :start,
        %{
          chat_id: chat_id,
          filename: filename,
          mime_type: mime_type,
          size_bytes: size,
          uploaded_bytes: 0,
          chunk_size_bytes: @default_chunk_size_bytes,
          status: :uploading,
          expires_at: expires_at
        },
        actor: actor
      )
      |> Ash.create(actor: actor)
      |> case do
        {:ok, %ChatUploadSession{} = upload} ->
          case File.write(upload_path(upload.external_id), "", [:binary]) do
            :ok ->
              {:ok, upload}

            {:error, reason} ->
              _ = destroy_upload_record(upload)
              {:error, "Failed to initialize upload storage: #{inspect(reason)}"}
          end

        {:error, error} ->
          {:error, error}
      end
    else
      nil -> {:error, "size_bytes must be a positive integer."}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "size_bytes must be a positive integer."}
    end
  end

  @spec get_upload(integer(), String.t(), term()) ::
          {:ok, ChatUploadSession.t()} | {:error, :not_found | String.t() | term()}
  def get_upload(chat_id, upload_id, actor) when is_integer(chat_id) do
    with {:ok, upload} <- fetch_upload(chat_id, upload_id, actor),
         {:ok, upload} <- maybe_mark_expired(upload) do
      {:ok, upload}
    end
  end

  @spec append_chunk(integer(), String.t(), non_neg_integer(), binary(), term()) ::
          {:ok, ChatUploadSession.t()}
          | {:error, {:offset_mismatch, non_neg_integer()}}
          | {:error, :not_found | String.t() | term()}
  def append_chunk(chat_id, upload_id, offset, payload, actor)
      when is_integer(chat_id) and is_integer(offset) and offset >= 0 and is_binary(payload) do
    with {:ok, %ChatUploadSession{} = upload} <- get_upload(chat_id, upload_id, actor),
         :ok <- ensure_uploading(upload),
         :ok <- ensure_expected_offset(upload, offset),
         :ok <- ensure_chunk_payload(upload, payload),
         :ok <- ensure_upload_root(),
         :ok <- append_payload(upload, payload),
         {:ok, updated} <- persist_uploaded_bytes(upload, offset + byte_size(payload), actor) do
      {:ok, updated}
    end
  end

  def append_chunk(_chat_id, _upload_id, _offset, _payload, _actor),
    do: {:error, "Invalid upload chunk."}

  @spec abort_upload(integer(), String.t(), term()) ::
          {:ok, ChatUploadSession.t()} | {:error, :not_found | String.t() | term()}
  def abort_upload(chat_id, upload_id, actor) when is_integer(chat_id) do
    with {:ok, %ChatUploadSession{} = upload} <- fetch_upload(chat_id, upload_id, actor),
         {:ok, upload} <- update_status(upload, :aborted, actor) do
      delete_upload_file(upload)
      {:ok, upload}
    end
  end

  @spec materialize_uploads(integer(), [String.t()], term()) ::
          {:ok, materialized_uploads()} | {:error, :not_found | String.t() | term()}
  def materialize_uploads(chat_id, upload_ids, actor)
      when is_integer(chat_id) and is_list(upload_ids) do
    with {:ok, sessions} <- fetch_uploaded_sessions(chat_id, upload_ids, actor) do
      Enum.reduce_while(sessions, {:ok, %{sessions: sessions, files: []}}, fn upload, {:ok, acc} ->
        with {:ok, payload} <- File.read(upload_path(upload.external_id)),
             {:ok, file} <-
               Files.create_from_upload(%{
                 filename: upload.filename,
                 mime_type: upload.mime_type,
                 payload: payload
               }) do
          {:cont, {:ok, %{acc | files: acc.files ++ [file]}}}
        else
          {:error, :enoent} ->
            rollback_materialized_files(acc.files)
            {:halt, {:error, "Uploaded file is no longer available."}}

          {:error, reason} ->
            rollback_materialized_files(acc.files)
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  def materialize_uploads(_chat_id, _upload_ids, _actor), do: {:error, "Invalid upload ids."}

  @spec finalize_materialized_uploads(materialized_uploads()) :: :ok
  def finalize_materialized_uploads(%{sessions: sessions}) when is_list(sessions) do
    Enum.each(sessions, fn upload ->
      delete_upload_file(upload)
      destroy_upload_record(upload)
    end)

    cleanup_stale_uploads!()
    :ok
  end

  def finalize_materialized_uploads(_other), do: :ok

  @spec rollback_materialized_uploads(materialized_uploads()) :: :ok
  def rollback_materialized_uploads(%{files: files}) when is_list(files) do
    rollback_materialized_files(files)
  end

  def rollback_materialized_uploads(_other), do: :ok

  @spec cleanup_stale_uploads!() :: :ok
  def cleanup_stale_uploads! do
    now = DateTime.utc_now()
    repo = Db.repo()

    rows =
      repo.all(
        from(u in "chat_upload_sessions",
          where:
            fragment("? IN ('aborted', 'expired')", field(u, :status)) or
              field(u, :expires_at) <= ^now,
          select: %{id: field(u, :id), external_id: field(u, :external_id)}
        )
      )

    Enum.each(rows, fn row ->
      delete_upload_file(row)
      destroy_upload_record_by_id(row.id)
    end)

    :ok
  end

  defp fetch_upload(chat_id, upload_id, actor) do
    with {:ok, normalized_id} <- normalize_external_id(upload_id) do
      ChatUploadSession
      |> Ash.Query.filter(chat_id == ^chat_id and external_id == ^normalized_id)
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %ChatUploadSession{} = upload} -> {:ok, upload}
        {:ok, nil} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp maybe_mark_expired(%ChatUploadSession{} = upload) do
    if DateTime.compare(upload.expires_at, DateTime.utc_now()) == :gt do
      {:ok, upload}
    else
      update_status_internal(upload, :expired)
    end
  end

  defp ensure_uploading(%ChatUploadSession{status: :uploading}), do: :ok
  defp ensure_uploading(%ChatUploadSession{status: :uploaded}), do: {:error, "Upload is already complete."}
  defp ensure_uploading(%ChatUploadSession{status: :aborted}), do: {:error, "Upload was aborted."}
  defp ensure_uploading(%ChatUploadSession{status: :expired}), do: {:error, "Upload session expired."}
  defp ensure_uploading(_upload), do: {:error, "Upload session is not writable."}

  defp ensure_expected_offset(%ChatUploadSession{uploaded_bytes: expected}, offset)
       when expected == offset,
       do: :ok

  defp ensure_expected_offset(%ChatUploadSession{uploaded_bytes: expected}, _offset),
    do: {:error, {:offset_mismatch, expected}}

  defp ensure_chunk_payload(%ChatUploadSession{} = upload, payload) do
    cond do
      byte_size(payload) == 0 ->
        {:error, "Upload chunk is empty."}

      byte_size(payload) > upload.chunk_size_bytes ->
        {:error, "Upload chunk exceeds the allowed chunk size."}

      upload.uploaded_bytes + byte_size(payload) > upload.size_bytes ->
        {:error, "Upload chunk exceeds the declared file size."}

      true ->
        :ok
    end
  end

  defp append_payload(%ChatUploadSession{} = upload, payload) do
    File.write(upload_path(upload.external_id), payload, [:append, :binary])
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to persist upload chunk: #{inspect(reason)}"}
    end
  end

  defp persist_uploaded_bytes(%ChatUploadSession{} = upload, uploaded_bytes, actor) do
    status = if uploaded_bytes >= upload.size_bytes, do: :uploaded, else: :uploading

    upload
    |> Ash.Changeset.for_update(
      :track_progress,
      %{uploaded_bytes: uploaded_bytes, status: status},
      actor: actor
    )
    |> Ash.update(actor: actor)
  end

  defp update_status(%ChatUploadSession{} = upload, status, actor) do
    upload
    |> Ash.Changeset.for_update(
      :mark_status,
      %{status: status, expires_at: DateTime.utc_now()},
      actor: actor
    )
    |> Ash.update(actor: actor)
  end

  defp update_status_internal(%ChatUploadSession{} = upload, status) do
    upload
    |> Ash.Changeset.for_update(
      :mark_status,
      %{status: status, expires_at: DateTime.utc_now()},
      authorize?: false
    )
    |> Ash.update(authorize?: false)
  end

  defp fetch_uploaded_sessions(chat_id, upload_ids, actor) do
    with {:ok, normalized_ids} <- normalize_upload_ids(upload_ids) do
      sessions =
        ChatUploadSession
        |> Ash.Query.filter(chat_id == ^chat_id and external_id in ^normalized_ids)
        |> Ash.Query.sort(created_at: :asc, id: :asc)
        |> Ash.read!(actor: actor)

      with true <- length(sessions) == length(normalized_ids) do
        sessions
        |> Enum.reduce_while({:ok, []}, fn upload, {:ok, acc} ->
          case maybe_mark_expired(upload) do
            {:ok, %{status: :uploaded} = refreshed} ->
              {:cont, {:ok, acc ++ [refreshed]}}

            {:ok, _refreshed} ->
              {:halt, {:error, "Upload is not complete yet."}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
      else
        false -> {:error, :not_found}
      end
    end
  end

  defp rollback_materialized_files(files) do
    Enum.each(files, fn file ->
      _ = Files.delete_file_and_maybe_payload(file.id)
    end)

    :ok
  end

  defp destroy_upload_record(%ChatUploadSession{id: id}), do: destroy_upload_record_by_id(id)
  defp destroy_upload_record(%{id: id}) when is_integer(id), do: destroy_upload_record_by_id(id)
  defp destroy_upload_record(_other), do: :ok

  defp destroy_upload_record_by_id(id) when is_integer(id) do
    case Ash.get(ChatUploadSession, id, authorize?: false) do
      {:ok, %ChatUploadSession{} = upload} ->
        _ = Ash.destroy(upload, authorize?: false)
        :ok

      _other ->
        :ok
    end
  end

  defp delete_upload_file(%ChatUploadSession{external_id: external_id}),
    do: delete_upload_file(%{external_id: external_id})

  defp delete_upload_file(%{external_id: external_id}) when is_binary(external_id) do
    _ = File.rm(upload_path(external_id))
    :ok
  end

  defp delete_upload_file(_other), do: :ok

  defp ensure_upload_root do
    File.mkdir_p(@upload_root)
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to prepare upload storage: #{inspect(reason)}"}
    end
  end

  defp upload_path(external_id) when is_binary(external_id) do
    Path.join(@upload_root, "#{external_id}.part")
  end

  defp normalize_external_id(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "Invalid upload id."}
    end
  end

  defp normalize_external_id(_other), do: {:error, "Invalid upload id."}

  defp normalize_upload_ids(upload_ids) when is_list(upload_ids) do
    upload_ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case normalize_external_id(to_string(id)) do
        {:ok, normalized} ->
          if normalized in acc do
            {:cont, {:ok, acc}}
          else
            {:cont, {:ok, acc ++ [normalized]}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_upload_ids(_other), do: {:error, "Invalid upload ids."}

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_integer(_other), do: nil
end
