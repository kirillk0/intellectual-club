defmodule IntellectualClub.SecretsCryptoKeyringTest do
  use ExUnit.Case, async: false

  alias IntellectualClub.Secrets.{Crypto, StartupMigrator}

  @aad_v1 "intellectual-club:managed-secret:v1"

  setup do
    current = Application.get_env(:intellectual_club, :managed_secrets_encryption_key)
    previous = Application.get_env(:intellectual_club, :managed_secrets_previous_encryption_keys)

    migrate_on_startup =
      Application.get_env(:intellectual_club, :migrate_managed_secrets_on_startup)

    on_exit(fn ->
      restore_env(:managed_secrets_encryption_key, current)
      restore_env(:managed_secrets_previous_encryption_keys, previous)
      restore_env(:migrate_managed_secrets_on_startup, migrate_on_startup)
    end)

    :ok
  end

  test "decrypts current and previous keys and upgrades both legacy and old-key envelopes" do
    old_material = String.duplicate("a", 48)
    new_material = String.duplicate("b", 48)

    Application.put_env(:intellectual_club, :managed_secrets_encryption_key, old_material)
    Application.delete_env(:intellectual_club, :managed_secrets_previous_encryption_keys)

    old_v2 = Crypto.encrypt("old-v2-value")
    assert Crypto.current_ciphertext?(old_v2)
    old_v1 = encrypt_v1("old-v1-value", old_material)

    Application.put_env(:intellectual_club, :managed_secrets_encryption_key, new_material)
    refute Crypto.current_ciphertext?(old_v2)

    Application.put_env(
      :intellectual_club,
      :managed_secrets_previous_encryption_keys,
      [old_material]
    )

    assert {:ok, "old-v2-value", %{version: 2, current?: false}} =
             Crypto.decrypt_with_metadata(old_v2)

    assert {:ok, "old-v1-value", %{version: 1, current?: false}} =
             Crypto.decrypt_with_metadata(old_v1)

    assert {:ok, upgraded_v2, true} = Crypto.reencrypt_if_needed(old_v2)
    assert {:ok, upgraded_v1, true} = Crypto.reencrypt_if_needed(old_v1)

    assert {:ok, "old-v2-value", %{version: 2, current?: true}} =
             Crypto.decrypt_with_metadata(upgraded_v2)

    assert {:ok, "old-v1-value", %{version: 2, current?: true}} =
             Crypto.decrypt_with_metadata(upgraded_v1)

    assert {:ok, ^upgraded_v2, false} = Crypto.reencrypt_if_needed(upgraded_v2)

    Application.delete_env(:intellectual_club, :managed_secrets_previous_encryption_keys)

    assert {:error, :invalid_ciphertext} = Crypto.decrypt(old_v2)
    assert {:error, :invalid_ciphertext} = Crypto.decrypt(old_v1)
    assert {:ok, "old-v2-value"} = Crypto.decrypt(upgraded_v2)
    assert {:ok, "old-v1-value"} = Crypto.decrypt(upgraded_v1)
  end

  test "an explicitly configured invalid current key never falls back and rekeys data" do
    old_material = String.duplicate("o", 48)
    intended_material = String.duplicate("n", 48)

    Application.put_env(:intellectual_club, :managed_secrets_encryption_key, old_material)
    ciphertext = Crypto.encrypt("must-remain-on-old-key")

    Application.put_env(:intellectual_club, :managed_secrets_encryption_key, "too-short")

    Application.put_env(
      :intellectual_club,
      :managed_secrets_previous_encryption_keys,
      [old_material]
    )

    assert_raise ArgumentError, ~r/current encryption key must be/, fn ->
      Crypto.validate_keyring!()
    end

    assert_raise ArgumentError, ~r/current encryption key must be/, fn ->
      Crypto.encrypt("must-not-use-endpoint-fallback")
    end

    Application.put_env(:intellectual_club, :migrate_managed_secrets_on_startup, true)

    assert_raise ArgumentError, ~r/current encryption key must be/, fn ->
      StartupMigrator.init([])
    end

    assert {:error, :invalid_ciphertext} = Crypto.reencrypt_if_needed(ciphertext)

    Application.put_env(
      :intellectual_club,
      :managed_secrets_encryption_key,
      intended_material
    )

    assert {:ok, "must-remain-on-old-key"} = Crypto.decrypt(ciphertext)
  end

  defp encrypt_v1(value, material) do
    key = :crypto.hash(:sha256, "intellectual-club:managed-secrets:key:v1:" <> material)
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, value, @aad_v1, true)

    <<1, nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)
end
