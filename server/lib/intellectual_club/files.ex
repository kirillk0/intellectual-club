defmodule IntellectualClub.Files do
  @moduledoc """
  Internal file storage domain with payload deduplication by SHA-256.
  """

  use Ash.Domain

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Db
  alias IntellectualClub.Files.File
  alias IntellectualClub.Files.FilePayload
  alias IntellectualClub.Files.FilesystemStorage

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
      storage_backend: :fs
    }

    with :ok <- FilesystemStorage.store(sha256, payload) do
      File
      |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
      |> Ash.create(authorize?: false)
    end
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
    with {:ok, %File{} = file} <- Ash.get(File, file_id, authorize?: false) do
      load_file_payload(file)
    end
  end

  def load_payload(_file_id), do: {:error, :invalid_file_id}

  @spec load_payload_by_external_id(String.t()) :: {:ok, {File.t(), binary()}} | {:error, term()}
  def load_payload_by_external_id(external_id) when is_binary(external_id) do
    with {:ok, %File{} = file} <- get_by_external_id(external_id) do
      load_file_payload(file)
    end
  end

  def load_payload_by_external_id(_external_id), do: {:error, :invalid_external_id}

  @spec delete_file_and_maybe_payload(integer()) :: :ok | {:error, term()}
  def delete_file_and_maybe_payload(file_id) when is_integer(file_id) do
    case Ash.get(File, file_id, authorize?: false) do
      {:ok, %File{} = file} ->
        repo = Db.repo()

        Ash.transact(
          File,
          fn ->
            :ok =
              file
              |> Ash.destroy!(authorize?: false)
              |> then(fn _ -> :ok end)

            if remaining_files_for_sha256(repo, file.sha256) == 0 do
              :ok = delete_payload_for_sha256(repo, file.sha256)
            end

            :ok
          end, return_notifications?: true)
        |> case do
          {:ok, :ok, _notifications} -> :ok
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

  @type migrate_stats :: %{
          required(:db_files) => non_neg_integer(),
          required(:unique_payloads) => non_neg_integer(),
          required(:payloads_written) => non_neg_integer(),
          required(:files_updated) => non_neg_integer(),
          required(:db_payloads_deleted) => non_neg_integer(),
          required(:missing_payloads) => [String.t()],
          required(:errors) => [map()]
        }

  @spec migrate_db_payloads_to_fs(keyword()) :: {:ok, migrate_stats()} | {:error, term()}
  def migrate_db_payloads_to_fs(opts \\ []) when is_list(opts) do
    delete_db_payloads? = Keyword.get(opts, :delete_db_payloads?, true)

    with {:ok, files} <- db_backend_files() do
      stats =
        files
        |> Enum.map(& &1.sha256)
        |> Enum.uniq()
        |> Enum.reduce(initial_migrate_stats(length(files)), fn sha256, stats ->
          migrate_sha256_to_fs(sha256, delete_db_payloads?, stats)
        end)

      {:ok, stats}
    end
  end

  @spec migrate_db_payloads_to_fs!(keyword()) :: migrate_stats()
  def migrate_db_payloads_to_fs!(opts \\ []) do
    case migrate_db_payloads_to_fs(opts) do
      {:ok, %{errors: [], missing_payloads: []} = stats} ->
        stats

      {:ok, stats} ->
        raise "failed to migrate DB file payloads to filesystem: #{inspect(stats)}"

      {:error, error} ->
        raise "failed to migrate DB file payloads to filesystem: #{inspect(error)}"
    end
  end

  defp load_file_payload(%File{storage_backend: :db} = file) do
    case Db.repo().get(FilePayload, file.sha256) do
      %FilePayload{} = payload_row -> {:ok, {file, payload_row.payload}}
      nil -> {:error, :payload_not_found}
    end
  end

  defp load_file_payload(%File{storage_backend: :fs} = file) do
    with {:ok, payload} <- FilesystemStorage.fetch(file.sha256) do
      {:ok, {file, payload}}
    end
  end

  defp load_file_payload(%File{storage_backend: backend}) do
    {:error, {:unsupported_storage_backend, backend}}
  end

  defp remaining_files_for_sha256(repo, sha256) do
    repo.one(from(file in "files", where: field(file, :sha256) == ^sha256, select: count("*"))) ||
      0
  end

  defp delete_payload_for_sha256(repo, sha256) do
    {_count, _rows} =
      repo.delete_all(from(payload in FilePayload, where: payload.sha256 == ^sha256))

    FilesystemStorage.delete(sha256)
  end

  defp db_backend_files do
    File
    |> Ash.Query.filter(storage_backend == :db)
    |> Ash.Query.sort(sha256: :asc)
    |> Ash.read(authorize?: false)
  end

  defp initial_migrate_stats(db_files_count) do
    %{
      db_files: db_files_count,
      unique_payloads: 0,
      payloads_written: 0,
      files_updated: 0,
      db_payloads_deleted: 0,
      missing_payloads: [],
      errors: []
    }
  end

  defp migrate_sha256_to_fs(sha256, delete_db_payloads?, stats) do
    repo = Db.repo()

    case repo.get(FilePayload, sha256) do
      %FilePayload{payload: payload} ->
        case FilesystemStorage.store(sha256, payload) do
          :ok ->
            case update_db_files_to_fs(repo, sha256, delete_db_payloads?) do
              {:ok, files_updated, db_payloads_deleted} ->
                %{
                  stats
                  | unique_payloads: stats.unique_payloads + 1,
                    payloads_written: stats.payloads_written + 1,
                    files_updated: stats.files_updated + files_updated,
                    db_payloads_deleted: stats.db_payloads_deleted + db_payloads_deleted
                }

              {:error, error} ->
                append_migrate_error(stats, sha256, error)
            end

          {:error, error} ->
            append_migrate_error(stats, sha256, error)
        end

      nil ->
        %{stats | missing_payloads: [sha256 | stats.missing_payloads]}
    end
  end

  defp update_db_files_to_fs(repo, sha256, delete_db_payloads?) do
    Ash.transact(
      File,
      fn ->
        files =
          File
          |> Ash.Query.filter(sha256 == ^sha256 and storage_backend == :db)
          |> Ash.read!(authorize?: false)

        Enum.each(files, fn file ->
          file
          |> Ash.Changeset.for_update(:update_storage_backend, %{storage_backend: :fs},
            authorize?: false
          )
          |> Ash.update!(authorize?: false)
        end)

        db_payloads_deleted =
          if delete_db_payloads? do
            {count, _rows} =
              repo.delete_all(from(payload in FilePayload, where: payload.sha256 == ^sha256))

            count
          else
            0
          end

        {length(files), db_payloads_deleted}
      end, return_notifications?: true)
    |> case do
      {:ok, {files_updated, db_payloads_deleted}, _notifications} ->
        {:ok, files_updated, db_payloads_deleted}

      {:error, error} ->
        {:error, error}
    end
  end

  defp append_migrate_error(stats, sha256, error) do
    %{stats | errors: [%{sha256: sha256, error: inspect(error)} | stats.errors]}
  end

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
