defmodule IntellectualClub.Files.UploadStaging do
  @moduledoc """
  Temporary staging paths for uploads before they become durable file records.
  """

  @valid_scopes [:chat, :outlet]

  @spec root_path() :: String.t()
  def root_path do
    Application.fetch_env!(:intellectual_club, :upload_staging_path)
  end

  @spec ensure_root() :: :ok | {:error, term()}
  def ensure_root do
    File.mkdir_p(root_path())
  end

  @spec ensure_scope(atom()) :: :ok | {:error, :invalid_scope | term()}
  def ensure_scope(scope) when scope in @valid_scopes do
    File.mkdir_p(scope_root(scope))
  end

  def ensure_scope(_scope), do: {:error, :invalid_scope}

  @spec chat_upload_path(String.t()) :: String.t()
  def chat_upload_path(upload_id) when is_binary(upload_id) do
    Path.join(scope_root(:chat), "#{upload_id}.part")
  end

  @spec new_temp_path(atom()) :: {:ok, String.t()} | {:error, :invalid_scope | term()}
  def new_temp_path(scope) when scope in @valid_scopes do
    with :ok <- ensure_scope(scope) do
      {:ok, Path.join(scope_root(scope), "#{Ecto.UUID.generate()}.upload")}
    end
  end

  def new_temp_path(_scope), do: {:error, :invalid_scope}

  @spec cleanup_path(String.t()) :: :ok | {:error, term()}
  def cleanup_path(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def cleanup_path(_path), do: :ok

  defp scope_root(:chat), do: Path.join(root_path(), "chat")
  defp scope_root(:outlet), do: Path.join(root_path(), "outlet")
end
