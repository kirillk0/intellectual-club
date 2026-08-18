defmodule IntellectualClub.Llm.Providers.Responses.Endpoint do
  @moduledoc """
  Resolves Responses API base URLs and their preferred transport.
  """

  @default_base_url "https://api.openai.com/v1"
  @supported_schemes ~w(http https ws wss)

  @type transport :: :http | :websocket

  @type t :: %{
          transport: transport(),
          http_base_url: String.t(),
          websocket_base_url: String.t()
        }

  @spec resolve(String.t() | nil, keyword()) :: {:ok, t()} | {:error, :invalid_base_url}
  def resolve(base_url, opts \\ []) when is_list(opts) do
    force_websocket? = Keyword.get(opts, :force_websocket?, false)

    with %URI{scheme: scheme, host: host} = uri <- URI.parse(default_base_url(base_url)),
         true <- scheme in @supported_schemes and is_binary(host) and host != "" do
      uri = %{uri | path: normalize_path(uri.path)}

      transport =
        if force_websocket? or scheme in ["ws", "wss"], do: :websocket, else: :http

      {:ok,
       %{
         transport: transport,
         http_base_url: uri |> Map.put(:scheme, http_scheme(scheme)) |> URI.to_string(),
         websocket_base_url: uri |> Map.put(:scheme, websocket_scheme(scheme)) |> URI.to_string()
       }}
    else
      _other -> {:error, :invalid_base_url}
    end
  end

  @spec default_base_url(String.t() | nil) :: String.t()
  def default_base_url(nil), do: @default_base_url
  def default_base_url(""), do: @default_base_url

  def default_base_url(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @default_base_url
      trimmed -> trimmed
    end
  end

  def default_base_url(value), do: to_string(value)

  defp normalize_path(nil), do: nil
  defp normalize_path("/"), do: nil
  defp normalize_path(path), do: String.trim_trailing(path, "/")

  defp http_scheme("http"), do: "http"
  defp http_scheme("ws"), do: "http"
  defp http_scheme("https"), do: "https"
  defp http_scheme("wss"), do: "https"

  defp websocket_scheme("http"), do: "ws"
  defp websocket_scheme("ws"), do: "ws"
  defp websocket_scheme("https"), do: "wss"
  defp websocket_scheme("wss"), do: "wss"
end
