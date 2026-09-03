defmodule IntellectualClub.Secrets.DriverSecrets do
  @moduledoc """
  Persists and resolves tool-driver credentials through managed secret rows.

  The `tool_instances.secrets` map is retained temporarily as a read fallback
  for installations that have not completed the automatic startup backfill.
  New writes are stored only in `managed_secrets` and
  `tool_instance_secrets`.
  """

  alias Ash.Changeset
  alias IntellectualClub.Repo
  alias IntellectualClub.Secrets.{Crypto, Secret, ToolInstanceSecret}
  alias IntellectualClub.Tools.{Registry, ToolInstance}

  require Ash.Query

  @spec values_for_changeset(Changeset.t()) :: {:ok, map()} | {:error, String.t()}
  def values_for_changeset(%Changeset{} = changeset) do
    case Changeset.fetch_argument(changeset, :effective_driver_secrets) do
      {:ok, %{} = values} -> {:ok, values}
      _other -> values(changeset.data)
    end
  end

  @spec apply_patch(ToolInstance.t() | map(), map(), map() | nil) :: map()
  def apply_patch(tool_instance, current, patch) when is_map(current) do
    current = canonicalize_values(tool_instance, current)
    patch = if is_map(patch), do: patch, else: %{}

    Enum.reduce(patch, current, fn {raw_key, value}, merged ->
      case normalize_key(raw_key) do
        nil ->
          merged

        raw_key ->
          key = canonical_key(tool_instance, raw_key)

          cond do
            empty_secret?(value) ->
              Map.delete(merged, key)

            is_map(value) ->
              current_nested =
                case Map.get(merged, key) do
                  %{} = nested -> nested
                  _other -> %{}
                end

              case apply_nested_patch(current_nested, value) do
                nested when map_size(nested) == 0 -> Map.delete(merged, key)
                nested -> Map.put(merged, key, nested)
              end

            true ->
              Map.put(merged, key, value)
          end
      end
    end)
  end

  @spec canonicalize_values(ToolInstance.t() | map(), map()) :: map()
  def canonicalize_values(tool_instance, values) when is_map(values) do
    values = normalize_values(values)

    Enum.reduce(values, %{}, fn {key, value}, canonicalized ->
      canonical = canonical_key(tool_instance, key)

      if canonical == key do
        Map.put(canonicalized, canonical, value)
      else
        Map.put_new(canonicalized, canonical, value)
      end
    end)
  end

  @spec values(ToolInstance.t() | map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def values(tool_instance, opts \\ [])

  def values(%{id: id} = tool_instance, opts) do
    legacy = legacy_values(tool_instance)
    query? = Keyword.get(opts, :query?, true)

    bindings_result =
      case loaded_driver_bindings_result(tool_instance) do
        {:ok, bindings} when query? ->
          if binding_values_loaded?(bindings),
            do: {:ok, bindings},
            else: read_driver_bindings(id)

        {:ok, bindings} ->
          {:ok, bindings}

        :not_loaded when is_integer(id) and query? ->
          read_driver_bindings(id)

        :not_loaded ->
          {:ok, []}
      end

    with {:ok, bindings} <- bindings_result,
         {:ok, stored} <- decode_bindings(bindings) do
      {:ok, canonicalize_values(tool_instance, Map.merge(stored, legacy))}
    end
  end

  def values(_other, _opts), do: {:ok, %{}}

  @spec hydrate(ToolInstance.t(), keyword()) ::
          {:ok, ToolInstance.t()} | {:error, String.t()}
  def hydrate(%ToolInstance{} = tool_instance, opts \\ []) do
    case values(tool_instance, opts) do
      {:ok, resolved} -> {:ok, %{tool_instance | secrets: resolved}}
      {:error, _message} = error -> error
    end
  end

  @spec hydrate!(ToolInstance.t(), keyword()) :: ToolInstance.t()
  def hydrate!(%ToolInstance{} = tool_instance, opts \\ []) do
    case hydrate(tool_instance, opts) do
      {:ok, hydrated} -> hydrated
      {:error, message} -> raise RuntimeError, message
    end
  end

  @doc "Returns stored driver keys without decrypting their values."
  @spec present_keys(ToolInstance.t() | map()) :: MapSet.t(String.t())
  def present_keys(tool_instance) when is_map(tool_instance) do
    legacy_keys =
      tool_instance
      |> legacy_values()
      |> Enum.reduce(MapSet.new(), fn {key, value}, keys ->
        if credential_present?(value), do: MapSet.put(keys, key), else: keys
      end)

    tool_instance
    |> loaded_driver_bindings()
    |> Enum.reduce(legacy_keys, fn binding, keys ->
      case normalize_key(Map.get(binding, :env_name)) do
        nil -> keys
        key -> MapSet.put(keys, key)
      end
    end)
    |> Enum.map(&canonical_key(tool_instance, &1))
    |> MapSet.new()
  end

  def present_keys(_other), do: MapSet.new()

  @spec sync(ToolInstance.t(), map(), Ash.Resource.record() | map()) ::
          {:ok, ToolInstance.t()} | {:error, term()}
  def sync(%ToolInstance{id: id} = tool_instance, desired, actor)
      when is_integer(id) and is_map(desired) do
    desired = canonicalize_values(tool_instance, desired)

    with {:ok, bindings} <- read_driver_bindings(id) do
      case Ash.transaction([Secret, ToolInstanceSecret], fn ->
             case do_sync(tool_instance, bindings, desired, actor) do
               :ok -> tool_instance
               {:error, error} -> Repo.rollback(error)
             end
           end) do
        {:ok, _tool_instance} -> {:ok, tool_instance}
        {:error, error} -> {:error, error}
      end
    end
  end

  def sync(%ToolInstance{}, _desired, _actor),
    do: {:error, "Driver secrets require a persisted tool instance."}

  @spec migrate_legacy(ToolInstance.t(), Ash.Resource.record() | map()) ::
          {:ok, ToolInstance.t()} | {:error, term()}
  def migrate_legacy(%ToolInstance{id: tool_instance_id}, actor)
      when is_integer(tool_instance_id) do
    case Ash.transaction([ToolInstance, Secret, ToolInstanceSecret], fn ->
           with {:ok, locked} <- lock_tool_instance(tool_instance_id),
                {:ok, migrated} <- migrate_locked_legacy(locked, actor) do
             migrated
           else
             {:error, error} -> Repo.rollback(error)
           end
         end) do
      {:ok, migrated} -> {:ok, migrated}
      {:error, error} -> {:error, error}
    end
  end

  defp lock_tool_instance(tool_instance_id) do
    ToolInstance
    |> Ash.Query.filter(id == ^tool_instance_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ToolInstance{} = tool_instance} -> {:ok, tool_instance}
      {:ok, nil} -> {:error, "Tool instance no longer exists."}
      {:error, error} -> {:error, error}
    end
  end

  defp migrate_locked_legacy(%ToolInstance{} = tool_instance, actor) do
    if map_size(legacy_values(tool_instance)) == 0 do
      {:ok, tool_instance}
    else
      with {:ok, desired} <- values(tool_instance),
           {:ok, _tool_instance} <- sync(tool_instance, desired, actor),
           {:ok, cleared} <- clear_legacy(tool_instance, actor) do
        {:ok, cleared}
      end
    end
  end

  defp do_sync(tool_instance, bindings, desired, actor) do
    existing = Map.new(bindings, &{to_string(&1.env_name), &1})

    with :ok <- upsert_desired(tool_instance, existing, desired, actor),
         :ok <- delete_removed(existing, desired, actor) do
      :ok
    end
  end

  defp upsert_desired(tool_instance, existing, desired, actor) do
    desired
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{key, value}, sequence}, :ok ->
      result =
        case Map.get(existing, key) do
          nil -> create_binding(tool_instance, key, value, sequence, actor)
          binding -> update_binding(binding, value, actor)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp create_binding(tool_instance, key, value, sequence, actor) do
    with {:ok, encoded} <- encode_value(value),
         {:ok, secret} <- create_secret(tool_instance, key, encoded, actor) do
      ToolInstanceSecret
      |> Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool_instance.id,
          secret_id: secret.id,
          env_name: key,
          kind: :driver,
          sequence: sequence,
          # Legacy binaries treat disabled bindings as unavailable managed
          # environment secrets and therefore cannot expose driver credentials.
          enabled: false
        },
        actor: actor
      )
      |> Ash.create(actor: actor)
      |> case do
        {:ok, _binding} ->
          :ok

        {:error, error} ->
          _ = Ash.destroy(secret, actor: actor)
          {:error, error}
      end
    end
  end

  defp create_secret(tool_instance, key, encoded, actor) do
    Secret
    |> Changeset.for_create(
      :create,
      %{
        name: secret_name(tool_instance, key),
        description: "Credential used by the tool driver.",
        value: encoded
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp update_binding(binding, value, actor) do
    with {:ok, encoded} <- encode_value(value),
         %Secret{} = secret <- Map.get(binding, :secret),
         {:ok, _secret} <-
           secret
           |> Changeset.for_update(:update, %{value: encoded}, actor: actor)
           |> Ash.update(actor: actor) do
      :ok
    else
      nil -> {:error, "Stored driver secret is unavailable."}
      {:error, error} -> {:error, error}
    end
  end

  defp delete_removed(existing, desired, actor) do
    existing
    |> Enum.reject(fn {key, _binding} -> Map.has_key?(desired, key) end)
    |> Enum.reduce_while(:ok, fn {_key, binding}, :ok ->
      binding
      |> Changeset.for_destroy(:destroy, %{}, actor: actor)
      |> Ash.destroy(actor: actor)
      |> case do
        :ok -> {:cont, :ok}
        {:ok, _binding} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp clear_legacy(tool_instance, actor) do
    tool_instance
    |> Changeset.for_update(:clear_legacy_driver_secrets, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp read_driver_bindings(tool_instance_id) do
    ToolInstanceSecret
    |> Ash.Query.filter(tool_instance_id == ^tool_instance_id and kind == :driver)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(secret: [:id, :encrypted_value])
    # Access to the parent tool has already been authorized by every caller.
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, bindings} -> {:ok, bindings}
      {:error, error} -> {:error, "Failed to load driver secrets: #{Exception.message(error)}"}
    end
  end

  defp decode_bindings(bindings) do
    Enum.reduce_while(bindings, {:ok, %{}}, fn binding, {:ok, values} ->
      with %Secret{encrypted_value: ciphertext} <- Map.get(binding, :secret),
           {:ok, encoded} <- Crypto.decrypt(ciphertext),
           {:ok, value} <- Jason.decode(encoded) do
        {:cont, {:ok, Map.put(values, to_string(binding.env_name), value)}}
      else
        _other ->
          {:halt,
           {:error, "Driver secret `#{binding.env_name}` could not be decrypted or decoded."}}
      end
    end)
  end

  defp binding_values_loaded?(bindings) do
    Enum.all?(bindings, fn binding ->
      match?(%Secret{encrypted_value: value} when is_binary(value), Map.get(binding, :secret))
    end)
  end

  defp loaded_driver_bindings(tool_instance) do
    case loaded_driver_bindings_result(tool_instance) do
      {:ok, bindings} -> bindings
      :not_loaded -> []
    end
  end

  defp loaded_driver_bindings_result(tool_instance) do
    case Map.get(tool_instance, :driver_secret_bindings) do
      bindings when is_list(bindings) -> {:ok, bindings}
      _other -> :not_loaded
    end
  end

  defp legacy_values(tool_instance) do
    case Map.get(tool_instance, :secrets) do
      %{} = values -> normalize_values(values)
      _other -> %{}
    end
  end

  defp apply_nested_patch(current, patch) when is_map(current) and is_map(patch) do
    Enum.reduce(patch, Map.new(current), fn {raw_key, value}, merged ->
      case normalize_key(raw_key) do
        nil ->
          merged

        key ->
          cond do
            empty_secret?(value) ->
              Map.delete(merged, key)

            is_map(value) ->
              current_nested =
                case Map.get(merged, key) do
                  %{} = nested -> nested
                  _other -> %{}
                end

              case apply_nested_patch(current_nested, value) do
                nested when map_size(nested) == 0 -> Map.delete(merged, key)
                nested -> Map.put(merged, key, nested)
              end

            true ->
              Map.put(merged, key, value)
          end
      end
    end)
  end

  defp canonical_key(tool_instance, key) do
    Map.get(driver_key_aliases(tool_instance), key, key)
  end

  defp driver_key_aliases(tool_instance) do
    tool_type =
      tool_instance
      |> Map.get(:type, "")
      |> to_string()
      |> String.trim()

    schema =
      try do
        Registry.driver_for_type!(tool_type).secrets_schema()
      rescue
        _exception -> nil
      end

    schema
    |> schema_properties()
    |> Enum.reduce(%{}, fn {raw_key, raw_spec}, aliases ->
      case normalize_key(raw_key) do
        nil ->
          aliases

        canonical ->
          raw_spec
          |> schema_aliases()
          |> Enum.reduce(Map.put(aliases, canonical, canonical), fn alias_key, aliases ->
            Map.put(aliases, alias_key, canonical)
          end)
      end
    end)
  end

  defp schema_properties(%{} = schema) do
    case Map.get(schema, "properties") do
      %{} = properties -> properties
      _other -> %{}
    end
  end

  defp schema_properties(_schema), do: %{}

  defp schema_aliases(%{} = spec) do
    spec
    |> Map.get("x-aliases", [])
    |> List.wrap()
    |> Enum.map(&normalize_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp schema_aliases(_spec), do: []

  defp empty_secret?(nil), do: true
  defp empty_secret?(value) when is_binary(value), do: String.trim(value) == ""
  defp empty_secret?(_value), do: false

  defp normalize_values(values) when is_map(values) do
    Enum.reduce(values, %{}, fn {raw_key, raw_value}, normalized ->
      case normalize_key(raw_key) do
        nil ->
          normalized

        key ->
          value = normalize_value(raw_value)

          if credential_present?(value) do
            Map.put(normalized, key, value)
          else
            normalized
          end
      end
    end)
  end

  defp normalize_value(%{} = value) do
    Enum.reduce(value, %{}, fn {key, nested}, normalized ->
      case normalize_key(key) do
        nil -> normalized
        key -> Map.put(normalized, key, normalize_value(nested))
      end
    end)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> nil
      key -> key
    end
  end

  defp normalize_key(key) when is_integer(key), do: Integer.to_string(key)
  defp normalize_key(_other), do: nil

  defp credential_present?(value) when is_binary(value), do: String.trim(value) != ""

  defp credential_present?(%{} = value),
    do: Enum.any?(value, fn {_key, item} -> credential_present?(item) end)

  defp credential_present?(_value), do: false

  defp encode_value(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, error} -> {:error, "Driver secret value is invalid: #{Exception.message(error)}"}
    end
  end

  defp secret_name(tool_instance, key) do
    type = tool_instance.type |> to_string() |> String.trim()
    String.slice("#{type}: #{key}", 0, 200)
  end
end
