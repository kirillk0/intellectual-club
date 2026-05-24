defmodule IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ModelDiscovery do
  @moduledoc """
  Model discovery for OpenRouter Chat Completions providers.
  """

  alias IntellectualClub.Llm.Auth
  alias IntellectualClub.Llm.Providers.Common.ModelDiscovery, as: CommonModelDiscovery

  @type model_option :: CommonModelDiscovery.model_option()

  @spec list_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def list_models(provider) when is_map(provider) do
    with {:ok, token} <- bearer_token(provider),
         {:ok, url} <-
           CommonModelDiscovery.models_url(provider, %{"supported_parameters" => "tools"}),
         {:ok, body} <-
           CommonModelDiscovery.request_json(url, [
             {"authorization", "Bearer " <> token},
             {"accept", "application/json"}
           ]) do
      parse_models(body)
    end
  end

  @doc false
  @spec parse_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def parse_models(%{"data" => []}), do: {:ok, []}

  def parse_models(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(&model_option/1)
    |> CommonModelDiscovery.normalize_model_options()
  end

  def parse_models(_body), do: {:error, "Unsupported model list response."}

  defp bearer_token(provider) do
    Auth.get_bearer_token(%{
      provider_id: Map.get(provider, :id),
      auth_method: Map.get(provider, :auth_method),
      api_key: Map.get(provider, :api_key),
      oauth_refresh_token: Map.get(provider, :oauth_refresh_token)
    })
  end

  defp model_option(%{"id" => id} = model) when is_binary(id) do
    %{
      id: String.trim(id),
      label: CommonModelDiscovery.label_or_id(Map.get(model, "name"), id),
      context_length:
        CommonModelDiscovery.parse_positive_integer(Map.get(model, "context_length")),
      supports_image_input:
        CommonModelDiscovery.input_modalities_include_image?(
          get_in(model, ["architecture", "input_modalities"])
        )
    }
  end

  defp model_option(_model), do: nil
end
