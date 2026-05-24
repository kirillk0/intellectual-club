defmodule IntellectualClub.Llm.Providers.Common.ModelDiscovery do
  @moduledoc """
  Shared model discovery HTTP and parser helpers for provider packages.
  """

  alias Req.Response

  @type model_option :: %{
          id: String.t(),
          label: String.t(),
          context_length: integer() | nil,
          supports_image_input: boolean() | nil
        }

  @spec list_openai_compatible_models(map(), keyword()) ::
          {:ok, [model_option()]} | {:error, String.t()}
  def list_openai_compatible_models(provider, opts) when is_map(provider) and is_list(opts) do
    with {:ok, token} <- bearer_token(provider),
         {:ok, url} <- models_url(provider, Keyword.get(opts, :query, %{})),
         {:ok, body} <- request_models(url, token),
         {:ok, models} <- parse_models(body) do
      {:ok, models}
    end
  end

  @spec list_anthropic_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def list_anthropic_models(provider) when is_map(provider) do
    with {:ok, api_key} <- api_key(provider),
         {:ok, url} <- models_url(provider, %{}),
         {:ok, body} <- request_anthropic_models(url, api_key),
         {:ok, models} <- parse_anthropic_models(body) do
      {:ok, models}
    end
  end

  @spec parse_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def parse_models(%{"data" => []}), do: {:ok, []}

  def parse_models(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(&openai_model_option/1)
    |> normalize_model_options()
  end

  def parse_models(%{"models" => []}), do: {:ok, []}

  def parse_models(%{"models" => models}) when is_list(models) do
    models
    |> Enum.map(&codex_model_option/1)
    |> normalize_model_options()
  end

  def parse_models(_body), do: {:error, "Unsupported model list response."}

  defp bearer_token(provider) do
    IntellectualClub.Llm.Auth.get_bearer_token(%{
      provider_id: Map.get(provider, :id),
      auth_method: Map.get(provider, :auth_method),
      api_key: Map.get(provider, :api_key),
      oauth_refresh_token: Map.get(provider, :oauth_refresh_token)
    })
  end

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

  defp models_url(%{base_url: base_url}, query) when is_map(query) do
    base_url = normalize_base_url(base_url)

    if base_url == "" do
      {:error, "Provider base URL is not set."}
    else
      {:ok, append_query(base_url <> "/models", query)}
    end
  end

  defp models_url(_provider, _query), do: {:error, "Provider base URL is not set."}

  defp request_models(url, token) do
    response =
      Req.get!(
        url: url,
        headers: [{"authorization", "Bearer " <> token}, {"accept", "application/json"}],
        connect_options: [timeout: 10_000],
        receive_timeout: 30_000,
        retry: false
      )

    case response do
      %Response{status: status, body: body} when status in 200..299 ->
        decode_body(body)

      %Response{status: status} ->
        {:error, "Provider model list request failed with HTTP #{status}."}
    end
  rescue
    _exception ->
      {:error, "Provider model list request failed."}
  end

  defp request_anthropic_models(url, api_key) do
    response =
      Req.get!(
        url: url,
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"},
          {"accept", "application/json"}
        ],
        connect_options: [timeout: 10_000],
        receive_timeout: 30_000,
        retry: false
      )

    case response do
      %Response{status: status, body: body} when status in 200..299 ->
        decode_body(body)

      %Response{status: status} ->
        {:error, "Provider model list request failed with HTTP #{status}."}
    end
  rescue
    _exception ->
      {:error, "Provider model list request failed."}
  end

  defp decode_body(%{} = body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, "Provider model list response is not a JSON object."}
      {:error, _error} -> {:error, "Provider model list response is not valid JSON."}
    end
  end

  defp decode_body(_body), do: {:error, "Provider model list response is not a JSON object."}

  defp openai_model_option(%{"id" => id} = model) when is_binary(id) do
    %{
      id: String.trim(id),
      label: label_or_id(Map.get(model, "name"), id),
      context_length: parse_positive_integer(Map.get(model, "context_length")),
      supports_image_input:
        input_modalities_include_image?(get_in(model, ["architecture", "input_modalities"]))
    }
  end

  defp openai_model_option(_model), do: nil

  defp parse_anthropic_models(%{"data" => []}), do: {:ok, []}

  defp parse_anthropic_models(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(&anthropic_model_option/1)
    |> normalize_model_options()
  end

  defp parse_anthropic_models(_body), do: {:error, "Unsupported model list response."}

  defp anthropic_model_option(%{"id" => id} = model) when is_binary(id) do
    %{
      id: String.trim(id),
      label: label_or_id(Map.get(model, "display_name"), id),
      context_length: nil,
      supports_image_input: nil
    }
  end

  defp anthropic_model_option(_model), do: nil

  defp codex_model_option(%{"slug" => slug} = model) when is_binary(slug) do
    %{
      id: String.trim(slug),
      label: label_or_id(Map.get(model, "display_name"), slug),
      context_length:
        parse_positive_integer(Map.get(model, "context_window")) ||
          parse_positive_integer(Map.get(model, "max_context_window")),
      supports_image_input: input_modalities_include_image?(Map.get(model, "input_modalities"))
    }
  end

  defp codex_model_option(_model), do: nil

  defp normalize_model_options(options) do
    models =
      options
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn option ->
        %{
          id: String.trim(option.id),
          label: String.trim(option.label),
          context_length: option.context_length,
          supports_image_input: option.supports_image_input
        }
      end)
      |> Enum.reject(&(&1.id == ""))
      |> Enum.uniq_by(& &1.id)

    if models == [] do
      {:error, "Provider model list response did not include any usable models."}
    else
      {:ok, models}
    end
  end

  defp label_or_id(label, id) when is_binary(label) do
    case String.trim(label) do
      "" -> String.trim(id)
      value -> value
    end
  end

  defp label_or_id(_label, id), do: String.trim(id)

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp input_modalities_include_image?(modalities) when is_list(modalities) do
    Enum.any?(modalities, &(to_string(&1) == "image"))
  end

  defp input_modalities_include_image?(_modalities), do: nil

  defp normalize_base_url(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp normalize_base_url(_value), do: ""

  defp append_query(url, params) when map_size(params) == 0, do: url

  defp append_query(url, params) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> URI.encode_query(params)
  end
end
