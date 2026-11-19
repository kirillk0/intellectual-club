defmodule IntellectualClub.Llm.Providers.Responses.CodexHeaders do
  @moduledoc """
  Responses headers for OAuth account selection and prompt cache affinity.
  """

  @spec session_headers(map()) :: [{String.t(), String.t()}]
  def session_headers(request) do
    key = Map.get(request, "prompt_cache_key", Map.get(request, :prompt_cache_key))

    if is_binary(key) and Regex.match?(~r/\A[\x09\x20-\x7E]+\z/, key) and String.trim(key) != "" do
      [{"session-id", key}]
    else
      []
    end
  end

  @spec put_account_id([{String.t(), String.t()}], String.t(), String.t()) ::
          [{String.t(), String.t()}]
  def put_account_id(headers, url, token) do
    with true <- codex_url?(url),
         {:ok, account_id} <- account_id(token) do
      List.keystore(headers, "chatgpt-account-id", 0, {"chatgpt-account-id", account_id})
    else
      _ -> headers
    end
  end

  defp codex_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, path: path}}
      when scheme in ["https", "wss"] and is_binary(host) and is_binary(path) ->
        String.downcase(host) == "chatgpt.com" and
          (path == "/backend-api/codex" or String.starts_with?(path, "/backend-api/codex/"))

      _ ->
        false
    end
  end

  defp account_id(token) when is_binary(token) do
    # These claims only select an account; the backend authenticates the bearer token.
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}}} <-
           Jason.decode(json),
         true <- is_binary(account_id) and Regex.match?(~r/\A[\x21-\x7E]+\z/, account_id) do
      {:ok, account_id}
    else
      _ -> :error
    end
  end

  defp account_id(_token), do: :error
end
