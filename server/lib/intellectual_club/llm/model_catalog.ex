defmodule IntellectualClub.Llm.ModelCatalog do
  @moduledoc """
  Facade for provider-owned model discovery.
  """

  alias IntellectualClub.Llm.Providers.Common.ProviderType
  alias IntellectualClub.Llm.Providers.Common.Registry

  @type model_option :: ProviderType.model_option()

  @spec list_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def list_models(provider) when is_map(provider) do
    case Registry.fetch(Map.get(provider, :type)) do
      {:ok, provider_module} ->
        provider_module.list_models(provider)

      {:error, :unknown_provider_type} ->
        {:error, "Provider type is not supported for model discovery."}
    end
  end
end
