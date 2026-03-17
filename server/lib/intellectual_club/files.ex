defmodule IntellectualClub.Files do
  @moduledoc """
  Internal file storage domain with payload deduplication by SHA-256.
  """

  use Ash.Domain

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Db
  alias IntellectualClub.Files.File
  alias IntellectualClub.Files.FilePayload

  require Ash.Query

  resources do
    resource(File)
  end

  @type upload_attrs :: %{
          required(:filename) => String.t(),
          required(:mime_type) => String.t(),
          required(:payload) => binary()
        }

  @spec create_from_upload(upload_attrs()) :: {:ok, File.t()} | {:error, term()}
  def create_from_upload(%{filename: filename, mime_type: mime_type, payload: payload})
      when is_binary(payload) do
    sha256 = sha256_hex(payload)

    attrs = %{
      sha256: sha256,
      filename: normalize_filename(filename),
      size_bytes: byte_size(payload),
      mime_type: normalize_mime_type(mime_type),
      storage_backend: :db
    }

    repo = Db.repo()

    repo.transaction(fn ->
      upsert_payload(repo, sha256, payload)

      File
      |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
      |> Ash.create!(authorize?: false)
    end)
    |> unwrap_transaction()
  end

  @spec create_from_binary(String.t(), String.t(), binary()) :: {:ok, File.t()} | {:error, term()}
  def create_from_binary(filename, mime_type, payload) when is_binary(payload) do
    create_from_upload(%{filename: filename, mime_type: mime_type, payload: payload})
  end

  @spec get_by_external_id(String.t()) :: {:ok, File.t()} | {:error, term()}
  def get_by_external_id(external_id) when is_binary(external_id) do
    File
    |> Ash.Query.filter(external_id == ^external_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %File{} = file} -> {:ok, file}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  def get_by_external_id(_external_id), do: {:error, :invalid_external_id}

  @spec duplicate_file(integer()) :: {:ok, File.t()} | {:error, term()}
  def duplicate_file(file_id) when is_integer(file_id) do
    with {:ok, %File{} = file} <- Ash.get(File, file_id, authorize?: false) do
      File
      |> Ash.Changeset.for_create(
        :create,
        %{
          sha256: file.sha256,
          filename: file.filename,
          size_bytes: file.size_bytes,
          mime_type: file.mime_type,
          storage_backend: file.storage_backend
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)
    end
  end

  def duplicate_file(_file_id), do: {:error, :invalid_file_id}

  @spec load_payload(integer()) :: {:ok, {File.t(), binary()}} | {:error, term()}
  def load_payload(file_id) when is_integer(file_id) do
    with {:ok, %File{} = file} <- Ash.get(File, file_id, authorize?: false),
         %FilePayload{} = payload_row <- Db.repo().get(FilePayload, file.sha256) do
      {:ok, {file, payload_row.payload}}
    else
      nil -> {:error, :payload_not_found}
      {:error, error} -> {:error, error}
    end
  end

  def load_payload(_file_id), do: {:error, :invalid_file_id}

  @spec load_payload_by_external_id(String.t()) :: {:ok, {File.t(), binary()}} | {:error, term()}
  def load_payload_by_external_id(external_id) when is_binary(external_id) do
    with {:ok, %File{} = file} <- get_by_external_id(external_id),
         %FilePayload{} = payload_row <- Db.repo().get(FilePayload, file.sha256) do
      {:ok, {file, payload_row.payload}}
    else
      nil -> {:error, :payload_not_found}
      {:error, error} -> {:error, error}
    end
  end

  def load_payload_by_external_id(_external_id), do: {:error, :invalid_external_id}

  @spec delete_file_and_maybe_payload(integer()) :: :ok | {:error, term()}
  def delete_file_and_maybe_payload(file_id) when is_integer(file_id) do
    case Ash.get(File, file_id, authorize?: false) do
      {:ok, %File{} = file} ->
        repo = Db.repo()

        repo.transaction(fn ->
          :ok =
            file
            |> Ash.destroy!(authorize?: false)
            |> then(fn _ -> :ok end)

          if remaining_files_for_sha256(repo, file.sha256) == 0 do
            _ =
              repo.delete_all(from(payload in FilePayload, where: payload.sha256 == ^file.sha256))
          end

          :ok
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  def delete_file_and_maybe_payload(_file_id), do: {:error, :invalid_file_id}

  @spec public_image(File.t() | nil, String.t()) :: map() | nil
  def public_image(nil, _url), do: nil

  def public_image(%File{} = file, url) when is_binary(url) do
    %{
      url: url,
      filename: file.filename,
      mime_type: file.mime_type,
      size_bytes: file.size_bytes,
      sha256: file.sha256
    }
  end

  defp upsert_payload(repo, sha256, payload) do
    %FilePayload{sha256: sha256, payload: payload}
    |> repo.insert(on_conflict: :nothing, conflict_target: [:sha256])
    |> case do
      {:ok, _row} -> :ok
      {:error, error} -> repo.rollback(error)
    end
  end

  defp remaining_files_for_sha256(repo, sha256) do
    repo.one(from(file in "files", where: field(file, :sha256) == ^sha256, select: count("*"))) ||
      0
  end

  defp unwrap_transaction({:ok, %File{} = file}), do: {:ok, file}
  defp unwrap_transaction({:error, error}), do: {:error, error}

  defp normalize_filename(filename) when is_binary(filename) do
    filename
    |> String.trim()
    |> case do
      "" -> "unnamed"
      value -> value
    end
  end

  defp normalize_filename(_filename), do: "unnamed"

  defp normalize_mime_type(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.trim()
    |> case do
      "" -> "application/octet-stream"
      value -> value
    end
  end

  defp normalize_mime_type(_mime_type), do: "application/octet-stream"

  defp sha256_hex(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end
