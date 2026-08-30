defmodule IntellectualClub.Secrets.Crypto do
  @moduledoc """
  Versioned authenticated encryption for persisted secret values.
  """

  @aad "intellectual-club:managed-secret:v1"
  @version 1
  @nonce_bytes 12
  @tag_bytes 16

  @spec encrypt(String.t()) :: binary()
  def encrypt(value) when is_binary(value) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, encryption_key(), nonce, value, @aad, true)

    <<@version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
      ciphertext::binary>>
  end

  @spec decrypt(binary()) :: {:ok, String.t()} | {:error, :invalid_ciphertext}
  def decrypt(
        <<@version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           encryption_key(),
           nonce,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      :error -> {:error, :invalid_ciphertext}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  rescue
    _ -> {:error, :invalid_ciphertext}
  end

  def decrypt(_other), do: {:error, :invalid_ciphertext}

  defp encryption_key do
    configured =
      Application.get_env(:intellectual_club, :managed_secrets_encryption_key) ||
        System.get_env("MANAGED_SECRETS_ENCRYPTION_KEY")

    material =
      case configured do
        value when is_binary(value) and byte_size(value) >= 32 -> value
        _ -> endpoint_secret_key_base()
      end

    :crypto.hash(:sha256, "intellectual-club:managed-secrets:key:v1:" <> material)
  end

  defp endpoint_secret_key_base do
    :intellectual_club
    |> Application.fetch_env!(IntellectualClubWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
