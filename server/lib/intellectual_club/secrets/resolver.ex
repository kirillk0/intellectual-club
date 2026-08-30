defmodule IntellectualClub.Secrets.Resolver do
  @moduledoc """
  Resolves model-selected secret names against the current tool call authority.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Secrets.{Crypto, KnowledgeBlockSecret, Secret, ToolInstanceSecret}
  alias IntellectualClub.Tools.{ExecutionContext, ToolInstance}

  require Ash.Query

  @spec resolve_selected(ToolInstance.t(), [String.t()] | nil, ExecutionContext.t() | nil) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, String.t()}
  def resolve_selected(%ToolInstance{} = tool_instance, requested, execution_context) do
    names = normalize_names(requested)

    if names == [] do
      {:ok, %{}}
    else
      with {:ok, actor} <- actor_for(execution_context),
           {:ok, bindings} <- available_bindings(tool_instance, execution_context, actor),
           :ok <- ensure_unambiguous(bindings, names),
           {:ok, selected} <- select_bindings(bindings, names),
           {:ok, values} <- decrypt_bindings(selected, actor) do
        {:ok, values}
      end
    end
  end

  def resolve_selected(_tool_instance, _requested, _execution_context),
    do: {:error, "Secret access requires a generation execution context."}

  @spec available_metadata(ToolInstance.t(), ExecutionContext.t() | nil) :: [map()]
  def available_metadata(%ToolInstance{} = tool_instance, %ExecutionContext{} = context) do
    with {:ok, actor} <- actor_for(context),
         {:ok, bindings} <- available_bindings(tool_instance, context, actor) do
      Enum.map(bindings, fn binding ->
        secret = Map.get(binding, :secret)

        %{
          env_name: binding.env_name,
          binding_external_id: binding.external_id,
          secret_name: if(is_map(secret), do: Map.get(secret, :name, ""), else: ""),
          description: if(is_map(secret), do: Map.get(secret, :description, ""), else: "")
        }
      end)
    else
      _ -> []
    end
  end

  def available_metadata(_tool_instance, _context), do: []

  defp actor_for(%ExecutionContext{owner_id: owner_id}) when is_integer(owner_id),
    do: {:ok, %User{id: owner_id}}

  defp actor_for(_context), do: {:error, "Secret access requires an authenticated owner."}

  defp available_bindings(%ToolInstance{id: tool_instance_id}, context, actor)
       when is_integer(tool_instance_id) do
    tool_bindings =
      ToolInstanceSecret
      |> Ash.Query.filter(tool_instance_id == ^tool_instance_id and enabled == true)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.Query.load([secret: [:id, :name, :description, :encrypted_value]], strict?: true)
      |> Ash.read(actor: actor)

    block_ids = normalize_external_ids(context.available_secret_binding_external_ids)

    block_bindings =
      if block_ids == [] do
        {:ok, []}
      else
        KnowledgeBlockSecret
        |> Ash.Query.filter(external_id in ^block_ids and enabled == true)
        |> Ash.Query.sort(sequence: :asc, id: :asc)
        |> Ash.Query.load([secret: [:id, :name, :description, :encrypted_value]], strict?: true)
        |> Ash.read(actor: actor)
      end

    with {:ok, tool_bindings} <- tool_bindings,
         {:ok, block_bindings} <- block_bindings do
      {:ok, tool_bindings ++ block_bindings}
    else
      {:error, error} ->
        {:error, "Failed to authorize available secrets: #{Exception.message(error)}"}
    end
  end

  defp available_bindings(_tool_instance, _context, _actor), do: {:ok, []}

  defp ensure_unambiguous(bindings, names) do
    ambiguous =
      Enum.find(names, fn name ->
        Enum.count(bindings, &(normalize_name(&1.env_name) == name)) > 1
      end)

    if ambiguous do
      {:error, "Secret name `#{ambiguous}` is ambiguous in this context."}
    else
      :ok
    end
  end

  defp select_bindings(bindings, names) do
    by_name = Map.new(bindings, &{normalize_name(&1.env_name), &1})

    case Enum.find(names, &(not Map.has_key?(by_name, &1))) do
      nil -> {:ok, Enum.map(names, &Map.fetch!(by_name, &1))}
      missing -> {:error, "Secret `#{missing}` is not available to this tool call."}
    end
  end

  defp decrypt_bindings(bindings, _actor) do
    Enum.reduce_while(bindings, {:ok, %{}}, fn binding, {:ok, values} ->
      case Map.get(binding, :secret) do
        %Secret{encrypted_value: ciphertext} when is_binary(ciphertext) ->
          case Crypto.decrypt(ciphertext) do
            {:ok, value} ->
              {:cont, {:ok, Map.put(values, binding.env_name, value)}}

            {:error, _reason} ->
              {:halt, {:error, "Secret `#{binding.env_name}` could not be decrypted."}}
          end

        _ ->
          {:halt, {:error, "Secret `#{binding.env_name}` is unavailable."}}
      end
    end)
  end

  defp normalize_names(names) when is_list(names) do
    names
    |> Enum.map(&normalize_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_names(nil), do: []
  defp normalize_names(_other), do: []

  defp normalize_name(value), do: value |> to_string() |> String.trim()

  defp normalize_external_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&normalize_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_external_ids(_other), do: []
end
