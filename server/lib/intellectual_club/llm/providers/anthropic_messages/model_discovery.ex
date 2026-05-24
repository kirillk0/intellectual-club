defmodule IntellectualClub.Llm.Providers.AnthropicMessages.ModelDiscovery do
  @moduledoc """
  Model discovery for Anthropic Messages API providers.
  """

  alias IntellectualClub.Llm.Providers.Common.ModelDiscovery, as: CommonModelDiscovery

  @type model_option :: CommonModelDiscovery.model_option()

  @spec list_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def list_models(provider) when is_map(provider) do
    with {:ok, api_key} <- api_key(provider),
         {:ok, url} <- CommonModelDiscovery.models_url(provider),
         {:ok, body} <-
           CommonModelDiscovery.request_json(
             url,
             [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"},
               {"accept", "application/json"}
             ],
             empty_on_statuses: [404],
             empty_body: %{"data" => []}
           ) do
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

  defp api_key(provider) when is_map(provider) do
    provider
    |> Map.get(:api_key)
    |> case do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, "Provider API key is not set."}, else: {:ok, value}

      _other ->
        {:error, "Provider API key is not set."}
    end
  end

  defp model_option(%{"id" => id} = model) when is_binary(id) do
    %{
      id: String.trim(id),
      label: CommonModelDiscovery.label_or_id(Map.get(model, "display_name"), id),
      context_length: nil,
      supports_image_input: nil
    }
  end

  defp model_option(_model), do: nil
end
