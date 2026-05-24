defmodule IntellectualClub.Llm.Providers.Common.ModelDiscovery do
  @moduledoc """
  Shared model discovery HTTP and normalization helpers for provider packages.
  """

  alias IntellectualClub.Llm.Providers.Common.ProviderType
  alias Req.Response

  @type model_option :: ProviderType.model_option()

  @spec models_url(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def models_url(provider, query \\ %{})

  def models_url(%{base_url: base_url}, query) when is_map(query) do
    base_url = normalize_base_url(base_url)

    if base_url == "" do
      {:error, "Provider base URL is not set."}
    else
      {:ok, append_query(base_url <> "/models", query)}
    end
  end

  def models_url(_provider, _query), do: {:error, "Provider base URL is not set."}

  @spec request_json(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def request_json(url, headers, opts \\ [])
      when is_binary(url) and is_list(headers) and is_list(opts) do
    response =
      Req.get!(
        url: url,
        headers: headers,
        connect_options: [timeout: 10_000],
        receive_timeout: 30_000,
        retry: false
      )

    case response do
      %Response{status: status, body: body} when status in 200..299 ->
        decode_body(body)

      %Response{status: status} ->
        if status in Keyword.get(opts, :empty_on_statuses, []) do
          {:ok, Keyword.get(opts, :empty_body, %{})}
        else
          {:error, "Provider model list request failed with HTTP #{status}."}
        end
    end
  rescue
    _exception ->
      {:error, "Provider model list request failed."}
  end

  @spec normalize_model_options([model_option() | nil]) ::
          {:ok, [model_option()]} | {:error, String.t()}
  def normalize_model_options(options) when is_list(options) do
    models =
      options
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn option ->
        id = trim_string(Map.get(option, :id))

        %{
          id: id,
          label: label_or_id(Map.get(option, :label), id),
          context_length: Map.get(option, :context_length),
          supports_image_input: Map.get(option, :supports_image_input)
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

  @spec label_or_id(term(), term()) :: String.t()
  def label_or_id(label, id) when is_binary(label) do
    case String.trim(label) do
      "" -> trim_string(id)
      value -> value
    end
  end

  def label_or_id(_label, id), do: trim_string(id)

  @spec parse_positive_integer(term()) :: integer() | nil
  def parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  def parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> nil
    end
  end

  def parse_positive_integer(_value), do: nil

  @spec input_modalities_include_image?(term()) :: boolean() | nil
  def input_modalities_include_image?(modalities) when is_list(modalities) do
    Enum.any?(modalities, &(to_string(&1) == "image"))
  end

  def input_modalities_include_image?(_modalities), do: nil

  defp decode_body(%{} = body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, "Provider model list response is not a JSON object."}
      {:error, _error} -> {:error, "Provider model list response is not valid JSON."}
    end
  end

  defp decode_body(_body), do: {:error, "Provider model list response is not a JSON object."}

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

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(_value), do: ""
end
