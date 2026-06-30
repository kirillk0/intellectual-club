defmodule IntellectualClubWeb.Bff.KnowledgeBlockFilesController do
  @moduledoc """
  Authenticated file attachment transport for knowledge blocks.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.UploadPolicy
  alias IntellectualClub.Files
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockFile
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.ImageControllerHelpers

  require Ash.Query

  def index(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         block_id when is_integer(block_id) <- Helpers.parse_optional_integer(id),
         {:ok, block} <- Ash.get(KnowledgeBlock, block_id, actor: actor),
         {:ok, attachments} <- list_attachments(block, actor) do
      json(conn, %{attachments: Enum.map(attachments, &serialize_attachment(&1, block.id))})
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        ImageControllerHelpers.render_not_found(conn)

      {:error, %Plug.Conn{} = conn} ->
        conn

      _other ->
        ImageControllerHelpers.render_not_found(conn)
    end
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         block_id when is_integer(block_id) <- Helpers.parse_optional_integer(id),
         {:ok, block} <- Ash.get(KnowledgeBlock, block_id, actor: actor),
         :ok <- require_owner(block, actor),
         {:ok, upload_attrs} <- validate_file_upload(Map.get(params, "file")),
         {:ok, enabled} <- validate_optional_enabled(params),
         {:ok, file} <-
           Files.create_from_path(
             upload_attrs.filename,
             upload_attrs.mime_type,
             upload_attrs.path
           ),
         {:ok, attachment} <- create_attachment(block, file, actor, enabled),
         {:ok, attachments} <- list_attachments(block, actor) do
      json(conn, %{
        attachment: serialize_attachment(attachment, block.id),
        attachments: Enum.map(attachments, &serialize_attachment(&1, block.id))
      })
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        ImageControllerHelpers.render_not_found(conn)

      {:error, :forbidden} ->
        render_forbidden(conn)

      {:error, message} when is_binary(message) ->
        ImageControllerHelpers.render_validation_error(conn, message)

      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        ImageControllerHelpers.render_action_error(conn, error)

      _other ->
        ImageControllerHelpers.render_not_found(conn)
    end
  end

  def show(conn, %{"id" => id, "attachment_id" => attachment_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         block_id when is_integer(block_id) <- Helpers.parse_optional_integer(id),
         attachment_id when is_integer(attachment_id) <-
           Helpers.parse_optional_integer(attachment_id),
         {:ok, block} <- Ash.get(KnowledgeBlock, block_id, actor: actor),
         {:ok, attachment} <- get_attachment(block.id, attachment_id, owner?(block, actor)),
         {:ok, {file, path}} <- Files.load_path(attachment.file_id) do
      ImageControllerHelpers.send_file_path(conn, file, path)
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        ImageControllerHelpers.render_not_found(conn)

      {:error, %Plug.Conn{} = conn} ->
        conn

      _other ->
        ImageControllerHelpers.render_not_found(conn)
    end
  end

  def update(conn, %{"id" => id, "attachment_id" => attachment_id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         block_id when is_integer(block_id) <- Helpers.parse_optional_integer(id),
         attachment_id when is_integer(attachment_id) <-
           Helpers.parse_optional_integer(attachment_id),
         {:ok, block} <- Ash.get(KnowledgeBlock, block_id, actor: actor),
         :ok <- require_owner(block, actor),
         {:ok, enabled} <- validate_enabled(params),
         {:ok, attachment} <- get_attachment(block.id, attachment_id, true),
         {:ok, attachment} <- update_attachment(attachment, enabled, actor),
         {:ok, attachments} <- list_attachments(block, actor) do
      json(conn, %{
        attachment: serialize_attachment(attachment, block.id),
        attachments: Enum.map(attachments, &serialize_attachment(&1, block.id))
      })
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        ImageControllerHelpers.render_not_found(conn)

      {:error, :forbidden} ->
        render_forbidden(conn)

      {:error, message} when is_binary(message) ->
        ImageControllerHelpers.render_validation_error(conn, message)

      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        ImageControllerHelpers.render_action_error(conn, error)

      _other ->
        ImageControllerHelpers.render_not_found(conn)
    end
  end

  def delete(conn, %{"id" => id, "attachment_id" => attachment_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         block_id when is_integer(block_id) <- Helpers.parse_optional_integer(id),
         attachment_id when is_integer(attachment_id) <-
           Helpers.parse_optional_integer(attachment_id),
         {:ok, block} <- Ash.get(KnowledgeBlock, block_id, actor: actor),
         :ok <- require_owner(block, actor),
         {:ok, attachment} <- get_attachment(block.id, attachment_id, true),
         :ok <- destroy_attachment(attachment, actor),
         {:ok, attachments} <- list_attachments(block, actor) do
      json(conn, %{attachments: Enum.map(attachments, &serialize_attachment(&1, block.id))})
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        ImageControllerHelpers.render_not_found(conn)

      {:error, :forbidden} ->
        render_forbidden(conn)

      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        ImageControllerHelpers.render_action_error(conn, error)

      _other ->
        ImageControllerHelpers.render_not_found(conn)
    end
  end

  defp require_owner(%KnowledgeBlock{owner_id: owner_id}, %{id: actor_id})
       when is_integer(owner_id) and owner_id == actor_id,
       do: :ok

  defp require_owner(_block, _actor), do: {:error, :forbidden}

  defp owner?(%KnowledgeBlock{owner_id: owner_id}, %{id: actor_id})
       when is_integer(owner_id) and owner_id == actor_id,
       do: true

  defp owner?(_block, _actor), do: false

  defp validate_enabled(%{"enabled" => enabled}) when is_boolean(enabled), do: {:ok, enabled}
  defp validate_enabled(%{"enabled" => "true"}), do: {:ok, true}
  defp validate_enabled(%{"enabled" => "false"}), do: {:ok, false}
  defp validate_enabled(_params), do: {:error, "Enabled must be true or false."}

  defp validate_optional_enabled(%{"enabled" => _enabled} = params), do: validate_enabled(params)
  defp validate_optional_enabled(_params), do: {:ok, true}

  defp validate_file_upload(nil), do: {:error, "File is required."}

  defp validate_file_upload(%Plug.Upload{} = upload) do
    filename = upload.filename |> to_string() |> String.trim()
    mime_type = normalize_mime_type(upload.content_type)
    max_bytes = UploadPolicy.default_max_file_size_bytes()

    with :ok <- validate_filename(filename),
         {:ok, stat} <- File.stat(upload.path),
         :ok <- validate_size(filename, stat.size, max_bytes) do
      {:ok, %{filename: filename, mime_type: mime_type, path: upload.path}}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, :enoent} ->
        {:error, "Uploaded file is no longer available."}

      {:error, reason} ->
        {:error, "Failed to read uploaded file: #{inspect(reason)}"}
    end
  end

  defp validate_file_upload(_other), do: {:error, "File is required."}

  defp validate_filename(""), do: {:error, "Filename is required."}
  defp validate_filename(_filename), do: :ok

  defp validate_size(_filename, size, _max_bytes) when is_integer(size) and size <= 0,
    do: {:error, "File is empty."}

  defp validate_size(filename, size, max_bytes)
       when is_integer(size) and is_integer(max_bytes) and size > max_bytes do
    {:error, "File #{inspect(filename)} exceeds the maximum size of #{format_size(max_bytes)}."}
  end

  defp validate_size(_filename, _size, _max_bytes), do: :ok

  defp create_attachment(%KnowledgeBlock{} = block, file, actor, enabled) do
    sequence = next_sequence(block.id)

    result =
      KnowledgeBlockFile
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, file_id: file.id, sequence: sequence, enabled: enabled},
        actor: actor
      )
      |> Ash.create(
        actor: actor,
        load: [file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]]
      )

    case result do
      {:ok, attachment} ->
        {:ok, attachment}

      {:error, error} ->
        _ = Files.delete_file_and_maybe_payload(file.id)
        {:error, error}
    end
  end

  defp destroy_attachment(%KnowledgeBlockFile{} = attachment, actor) do
    attachment
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
    |> Ash.destroy(actor: actor)
    |> case do
      :ok -> :ok
      {:ok, _destroyed} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp update_attachment(%KnowledgeBlockFile{} = attachment, enabled, actor)
       when is_boolean(enabled) do
    attachment
    |> Ash.Changeset.for_update(:update, %{enabled: enabled}, actor: actor)
    |> Ash.update(
      actor: actor,
      load: [file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]]
    )
  end

  defp get_attachment(block_id, attachment_id, include_disabled?)
       when is_integer(block_id) and is_integer(attachment_id) do
    query =
      KnowledgeBlockFile
      |> Ash.Query.filter(id == ^attachment_id and knowledge_block_id == ^block_id)

    query =
      if include_disabled? do
        query
      else
        Ash.Query.filter(query, enabled == true)
      end

    query
    |> Ash.Query.load([file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]],
      strict?: true
    )
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %KnowledgeBlockFile{} = attachment} -> {:ok, attachment}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp get_attachment(_block_id, _attachment_id, _include_disabled?), do: {:error, :not_found}

  defp list_attachments(%KnowledgeBlock{id: block_id} = block, actor) when is_integer(block_id) do
    query =
      KnowledgeBlockFile
      |> Ash.Query.filter(knowledge_block_id == ^block_id)

    query =
      if owner?(block, actor) do
        query
      else
        Ash.Query.filter(query, enabled == true)
      end

    attachments =
      query
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.Query.load([file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]],
        strict?: true
      )
      |> Ash.read!(authorize?: false)

    {:ok, attachments}
  end

  defp next_sequence(block_id) when is_integer(block_id) do
    KnowledgeBlockFile
    |> Ash.Query.filter(knowledge_block_id == ^block_id)
    |> Ash.Query.sort(sequence: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:sequence])
    |> Ash.read_one!(authorize?: false)
    |> case do
      %KnowledgeBlockFile{sequence: sequence} when is_integer(sequence) -> sequence + 1
      _other -> 0
    end
  end

  defp serialize_attachment(%KnowledgeBlockFile{} = attachment, block_id) do
    file = Map.get(attachment, :file)

    %{
      id: attachment.id,
      external_id: attachment.external_id,
      file_id: file && Map.get(file, :external_id),
      filename: file && Map.get(file, :filename),
      mime_type: file && Map.get(file, :mime_type),
      size_bytes: file && Map.get(file, :size_bytes),
      sha256: file && Map.get(file, :sha256),
      sequence: attachment.sequence || 0,
      enabled: attachment.enabled != false,
      url: "/api/bff/knowledge-blocks/#{block_id}/files/#{attachment.id}"
    }
  end

  defp normalize_mime_type(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.trim()
    |> case do
      "" -> "application/octet-stream"
      value -> value
    end
  end

  defp normalize_mime_type(_mime_type), do: "application/octet-stream"

  defp render_forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Forbidden"})
  end

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
