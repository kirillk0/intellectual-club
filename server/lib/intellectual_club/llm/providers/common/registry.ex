defmodule IntellectualClub.Llm.Providers.Common.Registry do
  @moduledoc """
  Discovers compiled LLM provider type modules.
  """

  alias IntellectualClub.Llm.Providers.Common.MissingProvider
  alias IntellectualClub.Llm.Providers.Common.ProviderType

  @provider_behaviour ProviderType

  @spec all() :: [module()]
  def all do
    discover_modules()
    |> provider_modules()
    |> build_index()
    |> Map.values()
    |> Enum.sort_by(& &1.type())
  end

  @spec metadata() :: [map()]
  def metadata do
    Enum.map(all(), & &1.metadata())
  end

  @spec fetch(term()) :: {:ok, module()} | {:error, :unknown_provider_type}
  def fetch(type) do
    normalized = normalize_type(type)

    case Map.fetch(index(), normalized) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_provider_type}
    end
  end

  @spec fetch_or_missing(term()) :: module()
  def fetch_or_missing(type) do
    case fetch(type) do
      {:ok, module} -> module
      {:error, :unknown_provider_type} -> MissingProvider
    end
  end

  @spec metadata_for_type(term()) :: {:ok, map()} | {:error, :unknown_provider_type}
  def metadata_for_type(type) do
    with {:ok, module} <- fetch(type) do
      {:ok, module.metadata()}
    end
  end

  @doc false
  def discover_modules do
    case :application.get_key(:intellectual_club, :modules) do
      {:ok, modules} when is_list(modules) -> modules
      _other -> []
    end
  end

  @doc false
  def provider_modules(modules) when is_list(modules) do
    modules
    |> Enum.filter(&provider_module?/1)
    |> Enum.sort()
  end

  @doc false
  def build_index(modules) when is_list(modules) do
    Enum.reduce(modules, %{}, fn module, acc ->
      type = module.type()

      if Map.has_key?(acc, type) do
        raise ArgumentError,
              "Duplicate LLM provider type #{inspect(type)} in #{inspect(acc[type])} and #{inspect(module)}"
      end

      Map.put(acc, type, module)
    end)
  end

  defp index do
    discover_modules()
    |> provider_modules()
    |> build_index()
  end

  defp provider_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :type, 0) and
      module != MissingProvider and
      function_exported?(module, :metadata, 0) and
      @provider_behaviour in behaviours(module)
  end

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  rescue
    _error -> []
  end

  defp normalize_type(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      type -> type
    end
  end

  defp normalize_type(_value), do: nil
end
