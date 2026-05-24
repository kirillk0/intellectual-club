defmodule IntellectualClub.Llm.Providers.Responses.ModelDiscovery do
  @moduledoc """
  Model discovery for Responses API providers.
  """

  alias IntellectualClub.Llm.Auth
  alias IntellectualClub.Llm.Providers.Common.ModelDiscovery, as: CommonModelDiscovery

  @type model_option :: CommonModelDiscovery.model_option()

  @spec list_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def list_models(provider) when is_map(provider) do
    with {:ok, token} <- bearer_token(provider),
         {:ok, url} <- CommonModelDiscovery.models_url(provider, %{"client_version" => "1.0.0"}),
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
    |> Enum.map(&openai_model_option/1)
    |> CommonModelDiscovery.normalize_model_options()
  end

  def parse_models(%{"models" => []}), do: {:ok, []}

  def parse_models(%{"models" => models}) when is_list(models) do
    models
    |> Enum.map(&codex_model_option/1)
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

  defp openai_model_option(%{"id" => id} = model) when is_binary(id) do
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

  defp openai_model_option(_model), do: nil

  defp codex_model_option(%{"slug" => slug} = model) when is_binary(slug) do
    %{
      id: String.trim(slug),
      label: CommonModelDiscovery.label_or_id(Map.get(model, "display_name"), slug),
      context_length:
        CommonModelDiscovery.parse_positive_integer(Map.get(model, "context_window")) ||
          CommonModelDiscovery.parse_positive_integer(Map.get(model, "max_context_window")),
      supports_image_input:
        CommonModelDiscovery.input_modalities_include_image?(Map.get(model, "input_modalities"))
    }
  end

  defp codex_model_option(_model), do: nil
end
