defmodule IntellectualClub.Llm.ModelCatalog do
  @moduledoc """
  Loads provider model lists and normalizes them for configuration forms.
  """

  alias Req.Response

  @type model_option :: %{
          id: String.t(),
          label: String.t(),
          context_length: integer() | nil,
          supports_image_input: boolean() | nil
        }

  @spec list_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}
  def list_models(%{type: :demo}), do: {:ok, []}
  def list_models(%{type: "demo"}), do: {:ok, []}

  def list_models(provider) when is_map(provider) do
    with {:ok, token} <- bearer_token(provider),
         {:ok, url} <- models_url(provider),
         {:ok, body} <- request_models(url, token),
         {:ok, models} <- parse_models(body) do
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

  defp models_url(%{type: type, base_url: base_url}) do
    base_url = normalize_base_url(base_url)

    cond do
      base_url == "" ->
        {:error, "Provider base URL is not set."}

      normalize_type(type) == :openrouter_chat_completion ->
        {:ok, append_query(base_url <> "/models", %{"supported_parameters" => "tools"})}

      normalize_type(type) == :responses ->
        {:ok, append_query(base_url <> "/models", %{"client_version" => "1.0.0"})}

      true ->
        {:error, "Provider type is not supported for model discovery."}
    end
  end

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

  defp normalize_type(value) when is_atom(value), do: value

  defp normalize_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp normalize_type(_value), do: nil

  defp append_query(url, params) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> URI.encode_query(params)
  end
end
