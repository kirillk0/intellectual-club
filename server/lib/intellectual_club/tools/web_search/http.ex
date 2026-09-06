defmodule IntellectualClub.Tools.WebSearch.Http do
  @moduledoc "Bounded HTTP requests and safe diagnostics for web providers."

  def request(cfg, method, path, payload, auth_header) do
    base = Map.fetch!(cfg, :api_base_url)
    url = String.trim_trailing(base, "/") <> path
    headers = [{"accept", "application/json"}, {"user-agent", cfg.user_agent}, auth_header]

    options = [
      method: method,
      url: url,
      headers: headers,
      retry: false,
      redirect: false,
      receive_timeout: cfg.timeout_ms,
      connect_options: [timeout: min(cfg.timeout_ms, 10_000)]
    ]

    options =
      if method == :get,
        do: Keyword.put(options, :params, payload),
        else: Keyword.put(options, :json, payload)

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        if body["success"] == false do
          {:error, error("provider_error", safe_message(body, cfg.token), status)}
        else
          {:ok, body}
        end

      {:ok, %{status: status, body: body}} when status not in 200..299 ->
        {:error, error("http_error", "HTTP #{status}: " <> safe_message(body, cfg.token), status)}

      {:ok, _} ->
        {:error, error("invalid_response", "Provider returned an invalid JSON response.")}

      {:error, reason} ->
        {:error, error("transport_error", transport_message(reason))}
    end
  rescue
    _ -> {:error, error("transport_error", "Provider request failed.")}
  end

  def error(code, message, status \\ nil),
    do: %{code: code, message: message, http_status: status}

  def safe_message(body, token \\ "") do
    message =
      case body do
        %{"error" => %{"message" => message}} when is_binary(message) -> message
        %{"error" => message} when is_binary(message) -> message
        %{"message" => message} when is_binary(message) -> message
        %{"detail" => message} when is_binary(message) -> message
        _ -> "Provider could not complete the request."
      end

    redact(message, [token])
  end

  def redact(message, secrets) when is_binary(message) do
    Enum.reduce(secrets, message, fn
      secret, text when is_binary(secret) and byte_size(secret) > 0 ->
        String.replace(text, secret, "[REDACTED]")

      _, text ->
        text
    end)
    |> String.replace(~r/[\x00-\x1f]/u, " ")
    |> String.slice(0, 500)
  end

  defp transport_message(%{reason: :timeout}), do: "Provider request timed out."
  defp transport_message(_), do: "Could not connect to provider."

  def search_results(items, snippet_key) when is_list(items) do
    if Enum.all?(items, &(is_map(&1) and is_binary(&1["url"]))) do
      {:ok,
       %{
         results:
           Enum.map(items, fn item ->
             snippet =
               case item[snippet_key] do
                 list when is_list(list) -> Enum.filter(list, &is_binary/1) |> Enum.join("\n")
                 text when is_binary(text) -> text
                 _ -> ""
               end

             %{"title" => string(item["title"]), "url" => item["url"], "description" => snippet}
           end),
         warnings: []
       }}
    else
      invalid_response()
    end
  end

  def search_results(_, _), do: invalid_response()

  def fetch_results(body, urls, content_key, error_key \\ "errors") do
    case body["results"] do
      items when is_list(items) ->
        {results, errors} =
          Enum.reduce(urls, {[], []}, fn url, {results, errors} ->
            item = Enum.find(items, &(is_map(&1) and (&1["url"] == url or &1["id"] == url)))

            cond do
              is_map(item) and is_binary(item[content_key]) and
                  byte_size(String.trim(item[content_key])) > 0 ->
                result = %{
                  "url" => url,
                  "final_url" => item["final_url"] || item["url"] || url,
                  "title" => item["title"],
                  "text" => item[content_key]
                }

                {[result | results], errors}

              true ->
                provider_error =
                  Enum.find(
                    List.wrap(body[error_key]),
                    &(is_map(&1) and (&1["url"] == url or &1["id"] == url))
                  )

                code =
                  if is_map(provider_error) and is_binary(provider_error["error"]),
                    do: String.slice(provider_error["error"], 0, 100),
                    else: "empty_content"

                {results,
                 [Map.put(error(code, "Could not extract readable content."), :url, url) | errors]}
            end
          end)

        {:ok, %{results: Enum.reverse(results), errors: Enum.reverse(errors), warnings: []}}

      _ ->
        invalid_response()
    end
  end

  def warnings(body) do
    List.wrap(body["warning"] || body["warnings"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.slice(&1, 0, 500))
  end

  def invalid_response,
    do: {:error, error("invalid_response", "Provider returned an unexpected response shape.")}

  defp string(value) when is_binary(value), do: value
  defp string(_), do: ""
end
