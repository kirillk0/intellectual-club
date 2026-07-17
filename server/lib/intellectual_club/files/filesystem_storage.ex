defmodule IntellectualClub.Files.FilesystemStorage do
  @moduledoc false

  require Logger

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

  @type store_status :: :created | :existing

  @spec store(String.t(), binary()) :: {:ok, store_status()} | {:error, term()}
  def store(sha256, payload) when is_binary(payload) do
    with {:ok, path} <- path_for(sha256),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      if File.exists?(path) do
        {:ok, :existing}
      else
        tmp_path = temporary_path(path)

        case File.write(tmp_path, payload, [:binary]) do
          :ok ->
            finalize_tmp_path(tmp_path, path)

          {:error, _reason} = error ->
            error
        end
      end
    end
  end

  def store(_sha256, _payload), do: {:error, :invalid_payload}

  @spec store_path(String.t(), String.t()) ::
          {:ok, store_status()} | {:error, term()}
  def store_path(sha256, source_path) when is_binary(source_path) do
    with {:ok, path} <- path_for(sha256),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      if File.exists?(path) do
        {:ok, :existing}
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
          case prune_empty_dirs(path) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "File payload was deleted but empty storage directories could not be pruned " <>
                  "sha256=#{sha256} reason=#{inspect(reason)}"
              )

              :ok
          end

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

  @spec list_payload_sha256s() :: {:ok, [String.t()]} | {:error, term()}
  def list_payload_sha256s do
    root_path()
    |> list_directory()
    |> case do
      {:ok, first_level_names} ->
        list_payload_sha256s(root_path(), first_level_names)

      {:error, reason} ->
        {:error, reason}
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
    case File.ln(tmp_path, path) do
      :ok ->
        _ = File.rm(tmp_path)
        {:ok, :created}

      {:error, :eexist} ->
        _ = File.rm(tmp_path)
        {:ok, :existing}

      {:error, reason} ->
        _ = File.rm(tmp_path)
        if File.exists?(path), do: {:ok, :existing}, else: {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{path}.#{suffix}.tmp"
  end

  defp list_payload_sha256s(root, first_level_names) do
    first_level_names
    |> Enum.filter(&hex_directory_name?/1)
    |> Enum.reduce_while({:ok, []}, fn first_level, {:ok, acc} ->
      first_level_path = Path.join(root, first_level)

      case list_directory(first_level_path) do
        {:ok, second_level_names} ->
          case payload_sha256s_in_second_level(
                 first_level_path,
                 first_level,
                 second_level_names
               ) do
            {:ok, sha256s} -> {:cont, {:ok, sha256s ++ acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, sha256s} -> {:ok, Enum.sort(sha256s)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload_sha256s_in_second_level(first_level_path, first_level, second_level_names) do
    second_level_names
    |> Enum.filter(&hex_directory_name?/1)
    |> Enum.reduce_while({:ok, []}, fn second_level, {:ok, acc} ->
      case list_directory(Path.join(first_level_path, second_level)) do
        {:ok, filenames} ->
          sha256s =
            filenames
            |> Enum.flat_map(&payload_sha256(&1, first_level, second_level))

          {:cont, {:ok, sha256s ++ acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp payload_sha256(filename, first_level, second_level) do
    with <<sha256::binary-size(64), ".blob">> <- filename,
         true <- Regex.match?(@sha256_pattern, sha256),
         true <- String.starts_with?(sha256, first_level <> second_level) do
      [sha256]
    else
      _other -> []
    end
  end

  defp list_directory(path) do
    case File.ls(path) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:list_directory_failed, path, reason}}
    end
  end

  defp hex_directory_name?(name) do
    byte_size(name) == 2 and Regex.match?(~r/\A[0-9a-f]{2}\z/, name)
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
