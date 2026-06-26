defmodule IntellectualClub.Tools.Drivers.SshKeyCb do
  @moduledoc """
  In-memory SSH client key callback.

  This callback intentionally avoids filesystem access (`~/.ssh`, known_hosts, key files).
  """

  @behaviour :ssh_client_key_api
  @compile {:no_warn_undefined,
            [
              {:ssh_file, :decode_ssh_file, 4},
              {:ssh_transport, :valid_key_sha_alg, 3}
            ]}
  @supported_algorithms %{
    "ssh-rsa" => :"ssh-rsa",
    "rsa-sha2-256" => :"rsa-sha2-256",
    "rsa-sha2-384" => :"rsa-sha2-384",
    "rsa-sha2-512" => :"rsa-sha2-512",
    "ecdsa-sha2-nistp256" => :"ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384" => :"ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521" => :"ecdsa-sha2-nistp521",
    "ssh-ed25519" => :"ssh-ed25519",
    "ssh-ed448" => :"ssh-ed448",
    "ssh-dss" => :"ssh-dss"
  }

  @impl true
  def is_host_key(_key, _host, _port, _algorithm, _opts), do: true

  @impl true
  def is_host_key(_key, _host, _algorithm, _opts), do: true

  @impl true
  def add_host_key(_host, _port, _public_key, _opts), do: :ok

  @impl true
  def add_host_key(_host, _public_key, _opts), do: :ok

  @impl true
  def user_key(algorithm, opts) do
    algorithm = normalize_algorithm(algorithm)

    with {:ok, private_key_text} <- fetch_private_key(opts),
         {:ok, keys} <- decode_private_keys(private_key_text),
         {:ok, key} <- pick_key_for_algorithm(keys, algorithm) do
      {:ok, key}
    else
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def sign(_pub_key_blob, _sig_data, _opts), do: {:error, :sign_not_supported}

  defp fetch_private_key(opts) when is_list(opts) do
    key_cb_private = Keyword.get(opts, :key_cb_private, [])

    private_key =
      key_cb_private
      |> Keyword.get(:private_key, "")
      |> to_string()
      |> String.trim()

    if private_key == "" do
      {:error, :no_identity}
    else
      {:ok, private_key}
    end
  end

  defp fetch_private_key(_opts), do: {:error, :no_identity}

  defp decode_private_keys(private_key_text) when is_binary(private_key_text) do
    pem =
      if String.ends_with?(private_key_text, "\n") do
        private_key_text
      else
        private_key_text <> "\n"
      end

    case :ssh_file.decode_ssh_file(:private, :any, pem, :ignore) do
      {:ok, keys} when is_list(keys) ->
        parsed =
          keys
          |> Enum.flat_map(fn
            {key, _attrs} -> [key]
            _other -> []
          end)

        if parsed == [] do
          {:error, :no_identity}
        else
          {:ok, parsed}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_private_key}
    end
  end

  defp pick_key_for_algorithm(keys, algorithm) when is_list(keys) and is_atom(algorithm) do
    case Enum.find(keys, fn key ->
           :ssh_transport.valid_key_sha_alg(:private, key, algorithm)
         end) do
      nil -> {:error, :no_identity}
      key -> {:ok, key}
    end
  rescue
    _exception ->
      {:error, :no_identity}
  end

  defp normalize_algorithm(algorithm) when is_atom(algorithm), do: algorithm

  defp normalize_algorithm(algorithm) when is_binary(algorithm) do
    algorithm
    |> String.trim()
    |> then(&Map.get(@supported_algorithms, &1, :"ssh-rsa"))
  end

  defp normalize_algorithm(algorithm) when is_list(algorithm) do
    algorithm
    |> to_string()
    |> normalize_algorithm()
  end

  defp normalize_algorithm(_algorithm), do: :"ssh-rsa"
end
