defmodule IntellectualClub.Secrets.Crypto do
  @moduledoc """
  Versioned authenticated encryption for persisted secret values.

  New ciphertexts include a non-secret key identifier. Decryption accepts the
  current key and configured previous keys so all managed secrets can be
  re-encrypted centrally during key rotation.

  The current material comes from `MANAGED_SECRETS_ENCRYPTION_KEY` (falling
  back to the endpoint secret), while previous materials can be supplied as a
  JSON array or comma-separated list in
  `MANAGED_SECRETS_PREVIOUS_ENCRYPTION_KEYS`.
  """

  @aad_v1 "intellectual-club:managed-secret:v1"
  @aad_v2 "intellectual-club:managed-secret:v2:"
  @version_v1 1
  @version_v2 2
  @nonce_bytes 12
  @tag_bytes 16
  @key_id_bytes 12
  @minimum_material_bytes 32

  @type decrypt_metadata :: %{
          current?: boolean(),
          key_id: String.t(),
          version: pos_integer()
        }

  @spec encrypt(String.t()) :: binary()
  def encrypt(value) when is_binary(value) do
    %{id: key_id, key: key} = current_key()
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    aad = @aad_v2 <> key_id

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, value, aad, true)

    <<@version_v2, byte_size(key_id), key_id::binary, nonce::binary-size(@nonce_bytes),
      tag::binary-size(@tag_bytes), ciphertext::binary>>
  end

  @spec decrypt(binary()) :: {:ok, String.t()} | {:error, :invalid_ciphertext}
  def decrypt(ciphertext) when is_binary(ciphertext) do
    case decrypt_with_metadata(ciphertext) do
      {:ok, plaintext, _metadata} -> {:ok, plaintext}
      {:error, :invalid_ciphertext} = error -> error
    end
  end

  def decrypt(_other), do: {:error, :invalid_ciphertext}

  @spec decrypt_with_metadata(binary()) ::
          {:ok, String.t(), decrypt_metadata()} | {:error, :invalid_ciphertext}
  def decrypt_with_metadata(<<@version_v2, key_id_size, rest::binary>>)
      when key_id_size > 0 do
    with true <- byte_size(rest) >= key_id_size + @nonce_bytes + @tag_bytes,
         <<key_id::binary-size(^key_id_size), nonce::binary-size(@nonce_bytes),
           tag::binary-size(@tag_bytes), ciphertext::binary>> <- rest,
         %{key: key} <- Enum.find(keyring(), &(&1.id == key_id)),
         plaintext when is_binary(plaintext) <-
           decrypt_aead(key, nonce, ciphertext, @aad_v2 <> key_id, tag) do
      {:ok, plaintext,
       %{version: @version_v2, key_id: key_id, current?: key_id == current_key().id}}
    else
      _other -> {:error, :invalid_ciphertext}
    end
  rescue
    _exception -> {:error, :invalid_ciphertext}
  end

  def decrypt_with_metadata(
        <<@version_v1, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      ) do
    Enum.find_value(keyring(), {:error, :invalid_ciphertext}, fn %{id: key_id, key: key} ->
      case decrypt_aead(key, nonce, ciphertext, @aad_v1, tag) do
        plaintext when is_binary(plaintext) ->
          {:ok, plaintext,
           %{version: @version_v1, key_id: key_id, current?: key_id == current_key().id}}

        :error ->
          false
      end
    end)
  rescue
    _exception -> {:error, :invalid_ciphertext}
  end

  def decrypt_with_metadata(_other), do: {:error, :invalid_ciphertext}

  @spec current_ciphertext?(binary()) :: boolean()
  def current_ciphertext?(<<@version_v2, key_id_size, rest::binary>>)
      when key_id_size > 0 and byte_size(rest) >= key_id_size + @nonce_bytes + @tag_bytes do
    <<key_id::binary-size(^key_id_size), _rest::binary>> = rest
    key_id == current_key().id
  rescue
    _exception -> false
  end

  def current_ciphertext?(_ciphertext), do: false

  @spec reencrypt_if_needed(binary()) ::
          {:ok, binary(), boolean()} | {:error, :invalid_ciphertext}
  def reencrypt_if_needed(ciphertext) when is_binary(ciphertext) do
    case decrypt_with_metadata(ciphertext) do
      {:ok, _plaintext, %{version: @version_v2, current?: true}} ->
        {:ok, ciphertext, false}

      {:ok, plaintext, _metadata} ->
        {:ok, encrypt(plaintext), true}

      {:error, :invalid_ciphertext} = error ->
        error
    end
  end

  def reencrypt_if_needed(_other), do: {:error, :invalid_ciphertext}

  @spec current_key_id() :: String.t()
  def current_key_id, do: current_key().id

  @spec validate_keyring!() :: :ok
  def validate_keyring! do
    _keys = keyring()
    :ok
  end

  defp decrypt_aead(key, nonce, ciphertext, aad, tag) do
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false)
  end

  defp current_key, do: hd(keyring())

  defp keyring do
    [current_key_material() | previous_key_materials()]
    |> Enum.map(&key_for_material/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp current_key_material do
    configured =
      Application.get_env(:intellectual_club, :managed_secrets_encryption_key) ||
        System.get_env("MANAGED_SECRETS_ENCRYPTION_KEY")

    case configured do
      nil -> endpoint_secret_key_base()
      value -> normalize_material!(value, "current")
    end
  end

  defp previous_key_materials do
    configured =
      Application.get_env(:intellectual_club, :managed_secrets_previous_encryption_keys) ||
        parse_previous_keys_env(System.get_env("MANAGED_SECRETS_PREVIOUS_ENCRYPTION_KEYS"))

    configured
    |> List.wrap()
    |> Enum.map(&normalize_material!(&1, "previous"))
  end

  defp parse_previous_keys_env(nil), do: []

  defp parse_previous_keys_env(value) when is_binary(value) do
    value = String.trim(value)

    case Jason.decode(value) do
      {:ok, keys} when is_list(keys) ->
        keys

      _other ->
        value
        |> String.split([",", "\n"], trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  defp normalize_material!(value, _kind)
       when is_binary(value) and byte_size(value) >= @minimum_material_bytes,
       do: value

  defp normalize_material!(_value, kind) do
    raise ArgumentError,
          "managed secrets #{kind} encryption key must be a binary of at least " <>
            "#{@minimum_material_bytes} bytes"
  end

  defp key_for_material(material) do
    key = :crypto.hash(:sha256, "intellectual-club:managed-secrets:key:v1:" <> material)

    key_id =
      :crypto.hash(:sha256, key)
      |> binary_part(0, @key_id_bytes)
      |> Base.url_encode64(padding: false)

    %{id: key_id, key: key}
  end

  defp endpoint_secret_key_base do
    :intellectual_club
    |> Application.fetch_env!(IntellectualClubWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
