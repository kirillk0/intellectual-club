defmodule IntellectualClub.Files.PayloadLock do
  @moduledoc false

  alias IntellectualClub.Repo

  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @spec acquire(String.t()) :: :ok | {:error, term()}
  def acquire(sha256) when is_binary(sha256) do
    with true <- Repo.in_transaction?() || {:error, :transaction_required},
         {:ok, {key_high, key_low}} <- lock_key(sha256),
         {:ok, _result} <-
           Repo.query("SELECT pg_advisory_xact_lock($1, $2)", [key_high, key_low]) do
      :ok
    end
  end

  def acquire(_sha256), do: {:error, :invalid_sha256}

  @doc false
  @spec lock_key(String.t()) :: {:ok, {integer(), integer()}} | {:error, :invalid_sha256}
  def lock_key(sha256) when is_binary(sha256) do
    sha256 = String.downcase(sha256)

    if Regex.match?(@sha256_pattern, sha256) do
      <<key_high::signed-32, key_low::signed-32, _rest::binary>> =
        Base.decode16!(sha256, case: :lower)

      {:ok, {key_high, key_low}}
    else
      {:error, :invalid_sha256}
    end
  end

  def lock_key(_sha256), do: {:error, :invalid_sha256}
end
