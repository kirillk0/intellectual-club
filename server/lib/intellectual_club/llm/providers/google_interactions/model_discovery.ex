defmodule IntellectualClub.Llm.Providers.GoogleInteractions.ModelDiscovery do
  @moduledoc """
  Model discovery for Google Interactions API providers.
  """

  alias IntellectualClub.Llm.Providers.Common.ModelDiscovery, as: CommonModelDiscovery

  @type model_option :: CommonModelDiscovery.model_option()

  @spec list_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def list_models(provider) when is_map(provider) do
    with {:ok, api_key} <- api_key(provider),
         {:ok, url} <- CommonModelDiscovery.models_url(provider),
         {:ok, body} <-
           CommonModelDiscovery.request_json(url, [
             {"x-goog-api-key", api_key},
             {"accept", "application/json"}
           ]) do
      parse_models(body)
    end
  end

  @doc false
  @spec parse_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def parse_models(%{"models" => []}), do: {:ok, []}

  def parse_models(%{"models" => models}) when is_list(models) do
    models
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

  defp model_option(%{"name" => name} = model) when is_binary(name) do
    id = normalize_model_name(name)

    %{
      id: id,
      label: CommonModelDiscovery.label_or_id(Map.get(model, "displayName"), id),
      context_length:
        CommonModelDiscovery.parse_positive_integer(Map.get(model, "inputTokenLimit")),
      supports_image_input: supports_image_input?(model)
    }
  end

  defp model_option(_model), do: nil

  defp normalize_model_name("models/" <> rest), do: String.trim(rest)
  defp normalize_model_name(name), do: String.trim(name)

  defp supports_image_input?(%{"input_modalities" => modalities}) do
    CommonModelDiscovery.input_modalities_include_image?(modalities)
  end

  defp supports_image_input?(%{"supportedInputModalities" => modalities}) do
    CommonModelDiscovery.input_modalities_include_image?(modalities)
  end

  defp supports_image_input?(%{"name" => name}) when is_binary(name) do
    normalized = name |> normalize_model_name() |> String.downcase()

    cond do
      String.starts_with?(normalized, "gemma") -> false
      String.starts_with?(normalized, "gemini") -> true
      true -> nil
    end
  end

  defp supports_image_input?(_model), do: nil
end
