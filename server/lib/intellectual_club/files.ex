defmodule IntellectualClub.Files do
  @moduledoc """
  Internal file storage domain with payload deduplication by SHA-256.
  """

  use Ash.Domain

  alias IntellectualClub.Files.File
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Files.GarbageCollector
  alias IntellectualClub.Files.PayloadLock

  require Ash.Query

  @hash_chunk_size_bytes 1024 * 1024

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

    sha256
    |> transact_with_payload_lock(fn ->
      with {:ok, referenced_before_store?} <- payload_referenced?(sha256),
           {:ok, store_status} <- FilesystemStorage.store(sha256, payload) do
        create_logical_file(attrs, store_status, referenced_before_store?)
      end
    end)
    |> request_collection_after_error(sha256)
  end

  @spec create_from_binary(String.t(), String.t(), binary()) :: {:ok, File.t()} | {:error, term()}
  def create_from_binary(filename, mime_type, payload) when is_binary(payload) do
    create_from_upload(%{filename: filename, mime_type: mime_type, payload: payload})
  end

  @spec create_from_path(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, File.t()} | {:error, term()}
  def create_from_path(filename, mime_type, source_path, opts \\ [])

  def create_from_path(filename, mime_type, source_path, _opts) when is_binary(source_path) do
    with {:ok, stat} <- Elixir.File.stat(source_path),
         :ok <- ensure_regular_file(stat),
         {:ok, sha256} <- sha256_file_hex(source_path) do
      attrs = %{
        sha256: sha256,
        filename: normalize_filename(filename),
        size_bytes: stat.size,
        mime_type: normalize_mime_type(mime_type),
        storage_backend: :fs
      }

      sha256
      |> transact_with_payload_lock(fn ->
        with {:ok, referenced_before_store?} <- payload_referenced?(sha256),
             {:ok, store_status} <- FilesystemStorage.store_path(sha256, source_path) do
          create_logical_file(attrs, store_status, referenced_before_store?)
        end
      end)
      |> request_collection_after_error(sha256)
    end
  end

  def create_from_path(_filename, _mime_type, _source_path, _opts),
    do: {:error, :invalid_source_path}

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
      transact_with_payload_lock(file.sha256, fn ->
        with {:ok, %File{} = current_file} <-
               Ash.get(File, file_id, authorize?: false) do
          File
          |> Ash.Changeset.for_create(
            :create,
            %{
              sha256: current_file.sha256,
              filename: current_file.filename,
              size_bytes: current_file.size_bytes,
              mime_type: current_file.mime_type,
              storage_backend: current_file.storage_backend
            },
            authorize?: false
          )
          |> Ash.create(authorize?: false)
        end
      end)
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

  @spec load_path(integer()) :: {:ok, {File.t(), String.t()}} | {:error, term()}
  def load_path(file_id) when is_integer(file_id) do
    with {:ok, %File{} = file} <- Ash.get(File, file_id, authorize?: false) do
      load_file_path(file)
    end
  end

  def load_path(_file_id), do: {:error, :invalid_file_id}

  @spec load_path_by_external_id(String.t()) :: {:ok, {File.t(), String.t()}} | {:error, term()}
  def load_path_by_external_id(external_id) when is_binary(external_id) do
    with {:ok, %File{} = file} <- get_by_external_id(external_id) do
      load_file_path(file)
    end
  end

  def load_path_by_external_id(_external_id), do: {:error, :invalid_external_id}

  @spec delete_file_and_maybe_payload(integer()) :: :ok | {:error, term()}
  def delete_file_and_maybe_payload(file_id) when is_integer(file_id) do
    case Ash.get(File, file_id, authorize?: false) do
      {:ok, %File{} = file} ->
        case transact_with_payload_lock(file.sha256, fn ->
               case Ash.get(File, file_id, authorize?: false) do
                 {:ok, %File{} = current_file} ->
                   normalize_file_destroy_result(Ash.destroy(current_file, authorize?: false))

                 {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
                   :ok

                 {:error, error} ->
                   {:error, error}
               end
             end) do
          :ok ->
            GarbageCollector.request_collection(file.sha256)
            :ok

          {:error, error} ->
            {:error, error}
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

  defp load_file_payload(%File{storage_backend: :fs} = file) do
    with {:ok, payload} <- FilesystemStorage.fetch(file.sha256) do
      {:ok, {file, payload}}
    end
  end

  defp load_file_payload(%File{storage_backend: backend}) do
    {:error, {:unsupported_storage_backend, backend}}
  end

  defp load_file_path(%File{storage_backend: :fs} = file) do
    with {:ok, path} <- FilesystemStorage.path_for(file.sha256) do
      if Elixir.File.exists?(path) do
        {:ok, {file, path}}
      else
        {:error, :payload_not_found}
      end
    end
  end

  defp load_file_path(%File{storage_backend: backend}) do
    {:error, {:unsupported_storage_backend, backend}}
  end

  defp create_logical_file(attrs, store_status, referenced_before_store?) do
    result =
      File
      |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
      |> Ash.create(authorize?: false)

    case result do
      {:ok, %File{}} = success ->
        success

      {:error, create_error} = error ->
        case compensate_new_payload(
               attrs.sha256,
               store_status,
               referenced_before_store?
             ) do
          :ok ->
            error

          {:error, compensation_error} ->
            {:error,
             {:logical_file_create_failed, create_error,
              {:payload_compensation_failed, compensation_error}}}
        end
    end
  end

  defp compensate_new_payload(_sha256, :existing, _referenced_before_store?), do: :ok
  defp compensate_new_payload(_sha256, :created, true), do: :ok
  defp compensate_new_payload(sha256, :created, false), do: FilesystemStorage.delete(sha256)

  defp normalize_file_destroy_result(:ok), do: :ok
  defp normalize_file_destroy_result({:ok, %File{}}), do: :ok
  defp normalize_file_destroy_result({:error, reason}), do: {:error, reason}

  defp request_collection_after_error({:error, _reason} = error, sha256) do
    GarbageCollector.request_collection(sha256)
    error
  end

  defp request_collection_after_error(result, _sha256), do: result

  defp payload_referenced?(sha256) do
    File
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.exists(authorize?: false)
  end

  defp transact_with_payload_lock(sha256, fun) when is_function(fun, 0) do
    File
    |> Ash.transact(
      fn ->
        with :ok <- PayloadLock.acquire(sha256) do
          fun.()
        end
      end,
      return_notifications?: true
    )
    |> case do
      {:ok, result, _notifications} -> result
      {:error, error} -> {:error, error}
    end
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

  defp sha256_file_hex(path) do
    Elixir.File.open(path, [:read, :binary], fn io ->
      io
      |> IO.binstream(@hash_chunk_size_bytes)
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
        :crypto.hash_update(context, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    end)
  end

  defp ensure_regular_file(%Elixir.File.Stat{type: :regular}), do: :ok
  defp ensure_regular_file(_stat), do: {:error, :invalid_source_path}
end
