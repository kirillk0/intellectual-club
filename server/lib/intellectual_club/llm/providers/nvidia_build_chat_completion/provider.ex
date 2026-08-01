defmodule IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion do
  @moduledoc """
  NVIDIA Build hosted NIM Chat Completions provider package.
  """

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  alias IntellectualClub.Generation.CacheControl
  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Llm.Providers.Common.AuthValidation
  alias IntellectualClub.Llm.Providers.Common.ChatAdapterHelpers
  alias IntellectualClub.Llm.Providers.Common.ChatCompletionsTrace
  alias IntellectualClub.Llm.Providers.Common.RequestBuilder
  alias IntellectualClub.Llm.Providers.Common.Steering
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion.ModelDiscovery

  @type_id "nvidia_build_chat_completion"
  @retryable_http_status_codes [429, 502, 503, 504, 529]

  @impl true
  def type, do: @type_id

  @impl true
  def label, do: "NVIDIA Build Chat Completions"

  @impl true
  def metadata do
    %{
      type: type(),
      label: label(),
      default_auth_method: "api_key",
      auth_methods: [
        %{value: "api_key", label: "API key", credential: "api_key", required: true}
      ],
      base_url_options: ["https://integrate.api.nvidia.com/v1"],
      default_base_url: "https://integrate.api.nvidia.com/v1",
      supports_model_discovery: true
    }
  end

  @impl true
  def validate_provider(provider, opts) do
    AuthValidation.validate(provider, Keyword.put(opts, :metadata, metadata()))
  end

  @impl true
  def list_models(provider), do: ModelDiscovery.list_models(provider)

  @impl true
  def supports_cache_control?, do: false

  @impl true
  def apply_standard_parameters(parameters, settings)
      when is_map(parameters) and is_map(settings) do
    parameters
    |> maybe_put_temperature(Map.get(settings, :temperature))
    |> maybe_put_reasoning_effort(Map.get(settings, :reasoning_effort))
  end

  @impl true
  def build_initial_request(opts) when is_map(opts) do
    messages =
      opts
      |> Map.put(:provider_type, type())
      |> Map.put(:cache_control_enabled, false)
      |> ChatAdapterHelpers.build_initial_messages()

    raw_request =
      RequestBuilder.build_chat_completions_payload(
        Map.get(opts, :model_name),
        Map.get(opts, :parameters, %{}) || %{},
        messages,
        tools: Map.get(opts, :tools, [])
      )
      |> prepare_request()

    %{
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def build_followup_request(opts) when is_map(opts) do
    context = Map.get(opts, :context, %{})
    runtime_step = Map.fetch!(opts, :runtime_step)
    previous_raw_request = RequestPayload.stringify_keys(runtime_step.raw_request || %{})

    followup =
      ChatAdapterHelpers.build_followup_messages(
        opts
        |> Map.put(:provider_type, type())
        |> Map.put(:cache_control_enabled, false)
        |> Map.put(:history_length, nil)
        |> Map.put(:supports_image_input, Map.get(context, :supports_image_input, false))
      )

    raw_request =
      RequestBuilder.build_chat_completions_payload(
        RequestPayload.model_name(previous_raw_request, Map.get(context, :model_name)),
        RequestPayload.parameters(previous_raw_request, Map.get(context, :parameters, %{})),
        followup.messages,
        tools: Map.get(opts, :tools, [])
      )
      |> prepare_request()

    %{
      runtime_step: followup.runtime_step,
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def inject_steering(raw_request, steering_items, _context)
      when is_map(raw_request) and is_list(steering_items) do
    payload = RequestPayload.stringify_keys(raw_request)

    messages =
      payload
      |> RequestPayload.messages()
      |> Kernel.++(
        Enum.map(Steering.texts(steering_items), &%{"role" => "user", "content" => &1})
      )

    raw_request =
      payload
      |> Map.put("messages", messages)
      |> prepare_request()

    %{raw_request: raw_request, request_snapshot: request_snapshot(raw_request)}
  end

  @impl true
  def request_snapshot(raw_request), do: ChatAdapterHelpers.request_snapshot(raw_request)

  @impl true
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    context = Map.get(opts, :context, %{})

    request_payload =
      (Map.get(opts, :request_payload) || %{})
      |> RequestPayload.stringify_keys()
      |> prepare_request()

    base_url = Map.get(context, :provider_base_url)
    api_key = Map.get(context, :provider_api_key)
    model_name = RequestPayload.model_name(request_payload)

    cond do
      not is_binary(base_url) or String.trim(base_url) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type),
          "Provider base URL is not set",
          request_payload
        )

      not is_binary(api_key) or String.trim(api_key) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type),
          "Provider API key is not set",
          request_payload
        )

      not is_binary(model_name) or String.trim(model_name) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type),
          "Configuration model_name is not set",
          request_payload
        )

      true ->
        ChatCompletionsTrace.stream_generate(
          %{
            provider: :nvidia_build_chat_completion,
            base_url: base_url,
            api_key: api_key,
            request_payload: request_payload,
            request_step_id: Map.get(opts, :request_step_id),
            timeout_ms: Map.get(opts, :timeout_ms, 300_000),
            retryable_http_status_codes: @retryable_http_status_codes
          },
          emit
        )
    end
  end

  defp maybe_put_temperature(parameters, nil), do: parameters

  defp maybe_put_temperature(parameters, temperature) do
    parameters
    |> RequestPayload.stringify_keys()
    |> Map.put("temperature", temperature)
  end

  defp maybe_put_reasoning_effort(parameters, nil), do: parameters

  defp maybe_put_reasoning_effort(parameters, effort) do
    parameters
    |> RequestPayload.stringify_keys()
    |> Map.delete("reasoning")
    |> Map.put("reasoning_effort", to_string(effort))
  end

  defp include_stream_usage(%{} = raw_request) do
    stream_options =
      case Map.get(raw_request, "stream_options") do
        %{} = options -> RequestPayload.stringify_keys(options)
        _other -> %{}
      end

    Map.put(raw_request, "stream_options", Map.put(stream_options, "include_usage", true))
  end

  defp prepare_request(%{} = raw_request) do
    raw_request
    |> Map.delete("session_id")
    |> strip_cache_control()
    |> include_stream_usage()
  end

  defp strip_cache_control(%{"messages" => messages} = raw_request) when is_list(messages) do
    Map.put(raw_request, "messages", Enum.map(messages, &CacheControl.remove_cache_control/1))
  end

  defp strip_cache_control(raw_request), do: raw_request

  defp emit_response_error(emit, provider, error_text, raw_request) do
    emit.(
      {:response_error,
       %{
         provider: provider,
         error_text: error_text,
         raw_request: raw_request,
         raw_response: nil
       }}
    )

    :ok
  end
end
