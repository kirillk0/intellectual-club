defmodule IntellectualClub.Generation.ProviderStream do
  @moduledoc """
  Provider streaming router.

  It is the single entry-point used by `Generation.Worker`. It selects a concrete
  provider implementation based on `provider_type` and ensures the worker only
  receives canonical runtime trace events.
  """

  alias IntellectualClub.Generation.DemoStreamTrace
  alias IntellectualClub.LlmCore.OpenRouterChatCompletionTrace
  alias IntellectualClub.LlmCore.ResponsesApi
  alias IntellectualClub.Llm.Auth

  @type trace_event :: IntellectualClub.Generation.RuntimeTrace.trace_event()

  @type event ::
          {:trace, trace_event()}
          | {:response_complete, map()}
          | {:response_error, map()}

  @spec stream_generate(map(), (event() -> any())) :: :ok
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    case Map.get(opts, :provider_type) do
      :demo ->
        DemoStreamTrace.stream_generate(opts, emit)

      :openrouter_chat_completion ->
        stream_openrouter(opts, emit)

      :openai_compatible ->
        # Backwards compatibility for early v2 data.
        stream_openrouter(opts, emit)

      :responses ->
        stream_responses(opts, emit)

      other ->
        emit.(
          {:response_error,
           %{
             provider: other,
             error_text: "Unsupported provider type: #{inspect(other)}",
             raw_request: Map.get(opts, :request_payload),
             raw_response: nil
           }}
        )

        :ok
    end
  end

  defp stream_openrouter(opts, emit) do
    base_url = Map.get(opts, :provider_base_url)
    api_key = Map.get(opts, :provider_api_key)
    model_name = Map.get(opts, :model_name)

    cond do
      not is_binary(base_url) or String.trim(base_url) == "" ->
        emit.(
          {:response_error,
           %{
             provider: :openrouter_chat_completion,
             error_text: "Provider base URL is not set",
             raw_request: Map.get(opts, :request_payload),
             raw_response: nil
           }}
        )

        :ok

      not is_binary(api_key) or String.trim(api_key) == "" ->
        emit.(
          {:response_error,
           %{
             provider: :openrouter_chat_completion,
             error_text: "Provider API key is not set",
             raw_request: Map.get(opts, :request_payload),
             raw_response: nil
           }}
        )

        :ok

      not is_binary(model_name) or String.trim(model_name) == "" ->
        emit.(
          {:response_error,
           %{
             provider: :openrouter_chat_completion,
             error_text: "Configuration model_name is not set",
             raw_request: Map.get(opts, :request_payload),
             raw_response: nil
           }}
        )

        :ok

      true ->
        OpenRouterChatCompletionTrace.stream_generate(
          %{
            base_url: base_url,
            api_key: api_key,
            model_name: model_name,
            parameters: Map.get(opts, :parameters, %{}) || %{},
            messages: Map.get(opts, :messages, []) || [],
            tools: Map.get(opts, :tools, []) || [],
            timeout_ms: Map.get(opts, :timeout_ms, 300_000)
          },
          emit
        )
    end
  end

  defp stream_responses(opts, emit) do
    token_result =
      Auth.get_bearer_token(%{
        provider_id: Map.get(opts, :provider_id),
        auth_method: Map.get(opts, :provider_auth_method),
        api_key: Map.get(opts, :provider_api_key),
        oauth_refresh_token: Map.get(opts, :provider_oauth_refresh_token)
      })

    case token_result do
      {:ok, token} ->
        ResponsesApi.stream_generate(
          %{
            base_url: Map.get(opts, :provider_base_url),
            api_key: token,
            model_name: Map.get(opts, :model_name),
            parameters: Map.get(opts, :parameters, %{}) || %{},
            messages: Map.get(opts, :messages, []) || [],
            request_payload: Map.get(opts, :request_payload),
            timeout_ms: Map.get(opts, :timeout_ms, 300_000)
          },
          emit
        )

      {:error, error_text} ->
        emit.(
          {:response_error,
           %{
             provider: :responses,
             error_text: error_text,
             raw_request: Map.get(opts, :request_payload),
             raw_response: nil
           }}
        )

        :ok
    end
  end
end
