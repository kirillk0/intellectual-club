defmodule IntellectualClub.Llm.Providers.ResponsesWss do
  @moduledoc """
  Responses API provider package using WebSocket transport.
  """

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  alias IntellectualClub.Llm.Auth
  alias IntellectualClub.Llm.Providers.Common.AuthValidation
  alias IntellectualClub.Llm.Providers.Responses
  alias IntellectualClub.Llm.Providers.ResponsesWss.Session

  @type_id "responses_wss"

  @impl true
  def type, do: @type_id

  @impl true
  def label, do: "Responses API (WSS)"

  @impl true
  def metadata do
    Responses.metadata()
    |> Map.put(:type, type())
    |> Map.put(:label, label())
  end

  @impl true
  def validate_provider(provider, opts) do
    AuthValidation.validate(provider, Keyword.put(opts, :metadata, metadata()))
  end

  @impl true
  def list_models(provider), do: Responses.list_models(provider)

  @impl true
  def supports_cache_control?, do: Responses.supports_cache_control?()

  @impl true
  def build_initial_request(opts), do: Responses.build_initial_request(opts)

  @impl true
  def build_followup_request(opts), do: Responses.build_followup_request(opts)

  @impl true
  def request_snapshot(raw_request), do: Responses.request_snapshot(raw_request)

  @impl true
  def start_session(context) when is_map(context) do
    Session.start(context)
  end

  @impl true
  def stop_session(session), do: Session.stop(session)

  @impl true
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    context = Map.get(opts, :context, %{})
    request_payload = stringify_keys(Map.get(opts, :request_payload, %{}) || %{})

    token_result =
      Auth.get_bearer_token_with_meta(%{
        provider_id: Map.get(context, :provider_id),
        auth_method: Map.get(context, :provider_auth_method),
        api_key: Map.get(context, :provider_api_key),
        oauth_refresh_token: Map.get(context, :provider_oauth_refresh_token)
      })

    case token_result do
      {:ok, token} ->
        case session_from_opts(opts, context) do
          {:ok, session, stop_after?} ->
            try do
              Session.stream_generate(
                session,
                %{
                  base_url: Map.get(context, :provider_base_url),
                  api_key: token,
                  request_payload: request_payload,
                  timeout_ms: Map.get(opts, :timeout_ms, 300_000),
                  connect_timeout_ms: Map.get(opts, :connect_timeout_ms, 10_000),
                  provider: Map.get(context, :provider_type, type())
                },
                emit
              )
            after
              if stop_after?, do: Session.stop(session)
            end

          {:error, error_text} ->
            emit_unavailable_error(context, request_payload, error_text, emit)
        end

      {:error, error_text, error_meta} ->
        emit_auth_error(context, request_payload, error_text, error_meta, emit)

      {:error, error_text} ->
        emit_auth_error(context, request_payload, error_text, %{}, emit)
    end
  end

  defp session_from_opts(opts, context) do
    case Map.get(opts, :provider_session) do
      pid when is_pid(pid) ->
        {:ok, pid, false}

      _other ->
        case start_session(context) do
          {:ok, pid} ->
            {:ok, pid, true}

          :ignore ->
            {:error, "Responses WSS session is not available."}

          {:error, reason} ->
            {:error, "Failed to start Responses WSS session: #{inspect(reason)}"}
        end
    end
  end

  defp emit_unavailable_error(context, request_payload, error_text, emit) do
    emit.(
      {:response_error,
       %{
         provider: Map.get(context, :provider_type, type()),
         error_text: error_text,
         retryable: false,
         error_kind: "transport",
         raw_request: request_payload,
         raw_response: nil
       }}
    )

    :ok
  end

  defp emit_auth_error(context, request_payload, error_text, error_meta, emit) do
    error_meta = if is_map(error_meta), do: error_meta, else: %{}

    emit.(
      {:response_error,
       Map.merge(
         error_meta,
         %{
           provider: Map.get(context, :provider_type, type()),
           error_text: error_text,
           raw_request: request_payload,
           raw_response: nil
         }
       )}
    )

    :ok
  end

  defp stringify_keys(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_keys(nested_value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
