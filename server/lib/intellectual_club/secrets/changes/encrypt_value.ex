defmodule IntellectualClub.Secrets.Changes.EncryptValue do
  @moduledoc """
  Encrypts a write-only `value` action argument into the persisted ciphertext.
  """

  use Ash.Resource.Change

  alias IntellectualClub.Secrets.Crypto

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :value) do
      {:ok, value} when is_binary(value) and value != "" ->
        Ash.Changeset.force_change_attribute(changeset, :encrypted_value, Crypto.encrypt(value))

      {:ok, _value} ->
        Ash.Changeset.add_error(changeset, field: :value, message: "must not be empty")

      :error ->
        changeset
    end
  end
end
