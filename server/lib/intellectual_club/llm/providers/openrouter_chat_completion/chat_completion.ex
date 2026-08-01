defmodule IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ChatCompletion do
  @moduledoc """
  OpenRouter configuration for the shared Chat Completions streaming client.
  """

  alias IntellectualClub.Llm.Providers.Common.ChatCompletions

  @app_headers [
    {"http-referer", "https://github.com/kirillk0/intellectual-club"},
    {"x-openrouter-title", "Intellectual Club"}
  ]

  @spec stream_generate(map(), (ChatCompletions.event() -> any())) :: :ok
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    extra_headers = @app_headers ++ List.wrap(Map.get(opts, :extra_headers, []))

    opts
    |> Map.put(:provider, :openrouter_chat_completion)
    |> Map.put(:extra_headers, extra_headers)
    |> ChatCompletions.stream_generate(emit)
  end
end
