defmodule IntellectualClub.Files.FilesystemStorage do
  @moduledoc false

  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @spec root_path() :: String.t()
  def root_path do
    Application.fetch_env!(:intellectual_club, :file_storage_path)
  end

  @spec path_for(String.t()) :: {:ok, String.t()} | {:error, :invalid_sha256}
  def path_for(sha256) when is_binary(sha256) do
    sha256 = String.downcase(sha256)

    if Regex.match?(@sha256_pattern, sha256) do
      {:ok,
       root_path()
       |> Path.join(binary_part(sha256, 0, 2))
       |> Path.join(binary_part(sha256, 2, 2))
       |> Path.join("#{sha256}.blob")}
    else
      {:error, :invalid_sha256}
    end
  end

  def path_for(_sha256), do: {:error, :invalid_sha256}

  @spec store(String.t(), binary()) :: :ok | {:error, term()}
  def store(sha256, payload) when is_binary(payload) do
    with {:ok, path} <- path_for(sha256),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      if File.exists?(path) do
        :ok
      else
        tmp_path = temporary_path(path)

        case File.write(tmp_path, payload, [:binary]) do
          :ok ->
            case File.rename(tmp_path, path) do
              :ok ->
                :ok

              {:error, reason} ->
                _ = File.rm(tmp_path)
                if File.exists?(path), do: :ok, else: {:error, reason}
            end

          {:error, _reason} = error ->
            error
        end
      end
    end
  end

  def store(_sha256, _payload), do: {:error, :invalid_payload}

  @spec store_path(String.t(), String.t()) :: :ok | {:error, term()}
  def store_path(sha256, source_path) when is_binary(source_path) do
    with {:ok, path} <- path_for(sha256),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      if File.exists?(path) do
        :ok
      else
        tmp_path = temporary_path(path)

        case link_or_copy(source_path, tmp_path) do
          :ok ->
            finalize_tmp_path(tmp_path, path)

          {:error, _reason} = error ->
            _ = File.rm(tmp_path)
            error
        end
      end
    end
  end

  def store_path(_sha256, _source_path), do: {:error, :invalid_source_path}

  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(sha256) do
    with {:ok, path} <- path_for(sha256) do
      case File.read(path) do
        {:ok, payload} -> {:ok, payload}
        {:error, :enoent} -> {:error, :payload_not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(sha256) do
    with {:ok, path} <- path_for(sha256) do
      case File.rm(path) do
        :ok ->
          prune_empty_dirs(path)

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(sha256) do
    case path_for(sha256) do
      {:ok, path} -> File.exists?(path)
      {:error, _reason} -> false
    end
  end

  defp link_or_copy(source_path, tmp_path) do
    case File.ln(source_path, tmp_path) do
      :ok -> :ok
      {:error, _reason} -> File.copy(source_path, tmp_path) |> normalize_copy_result()
    end
  end

  defp normalize_copy_result({:ok, _bytes}), do: :ok
  defp normalize_copy_result({:error, _reason} = error), do: error

  defp finalize_tmp_path(tmp_path, path) do
    case File.rename(tmp_path, path) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp_path)
        if File.exists?(path), do: :ok, else: {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{path}.#{suffix}.tmp"
  end

  defp prune_empty_dirs(path) do
    root = Path.expand(root_path())

    path
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      expanded = Path.expand(dir)

      cond do
        expanded == root ->
          {:halt, :ok}

        !path_inside?(expanded, root) ->
          {:halt, :ok}

        true ->
          case File.rmdir(expanded) do
            :ok -> {:cont, :ok}
            {:error, :enoent} -> {:cont, :ok}
            {:error, :eexist} -> {:halt, :ok}
            {:error, :enotempty} -> {:halt, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp path_inside?(path, root) do
    path_segments = Path.split(path)
    root_segments = Path.split(root)

    Enum.take(path_segments, length(root_segments)) == root_segments
  end
end
