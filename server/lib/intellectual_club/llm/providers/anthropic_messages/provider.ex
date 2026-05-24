defmodule IntellectualClub.Llm.Providers.AnthropicMessages do
  @moduledoc """
  Anthropic Messages API provider package.
  """

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.AnthropicMessages.Api
  alias IntellectualClub.Llm.Providers.AnthropicMessages.Payload
  alias IntellectualClub.Llm.Providers.Common.AuthValidation
  alias IntellectualClub.Llm.Providers.Common.ChatAdapterHelpers
  alias IntellectualClub.Llm.Providers.Common.ModelDiscovery
  alias IntellectualClub.Llm.Providers.Common.TraceHelpers

  @type_id "anthropic_messages"
  @anthropic_base_url "https://api.anthropic.com/v1"
  @deepseek_anthropic_base_url "https://api.deepseek.com/anthropic"
  @opaque_sequence 10_000

  @impl true
  def type, do: @type_id

  @impl true
  def label, do: "Anthropic Messages API"

  @impl true
  def metadata do
    %{
      type: type(),
      label: label(),
      default_auth_method: "api_key",
      auth_methods: [
        %{value: "api_key", label: "API key", credential: "api_key", required: true}
      ],
      base_url_options: [@anthropic_base_url, @deepseek_anthropic_base_url],
      default_base_url: @anthropic_base_url,
      supports_model_discovery: true
    }
  end

  @impl true
  def validate_provider(provider, opts) do
    AuthValidation.validate(provider, Keyword.put(opts, :metadata, metadata()))
  end

  @impl true
  def list_models(provider) do
    ModelDiscovery.list_anthropic_models(provider, empty_on_statuses: [404])
  end

  @impl true
  def supports_cache_control?, do: true

  @impl true
  def build_initial_request(opts) when is_map(opts) do
    {system, messages} =
      opts
      |> Map.put(:provider_type, type())
      |> ChatAdapterHelpers.build_initial_messages()
      |> Payload.from_chat_messages()

    raw_request =
      Payload.build_messages_payload(
        Map.get(opts, :model_name),
        Map.get(opts, :parameters, %{}) || %{},
        messages,
        system: system,
        tools: Map.get(opts, :tools, [])
      )

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

    {tool_result_message, runtime_step} =
      apply_tool_results(runtime_step, Map.get(opts, :results, []))

    messages =
      previous_raw_request
      |> Map.get("messages", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Kernel.++([assistant_message(runtime_step.raw_response, runtime_step)])
      |> Kernel.++(List.wrap(tool_result_message))
      |> Enum.reject(&is_nil/1)

    raw_request =
      Payload.build_messages_payload(
        RequestPayload.model_name(previous_raw_request, Map.get(context, :model_name)),
        RequestPayload.parameters(previous_raw_request, Map.get(context, :parameters, %{})),
        messages,
        system: Map.get(previous_raw_request, "system", Map.get(context, :system_prompt)),
        tools: Map.get(opts, :tools, [])
      )
      |> maybe_apply_followup_cache_control(context)

    %{
      runtime_step: runtime_step,
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def request_snapshot(raw_request), do: Payload.request_snapshot(raw_request)

  @impl true
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    context = Map.get(opts, :context, %{})

    request_payload =
      opts
      |> Map.get(:request_payload, %{})
      |> RequestPayload.stringify_keys()

    base_url = Map.get(context, :provider_base_url)
    api_key = Map.get(context, :provider_api_key)
    model_name = RequestPayload.model_name(request_payload)

    cond do
      not is_binary(base_url) or String.trim(base_url) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type, type()),
          "Provider base URL is not set",
          request_payload
        )

      not is_binary(api_key) or String.trim(api_key) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type, type()),
          "Provider API key is not set",
          request_payload
        )

      not is_binary(model_name) or String.trim(model_name) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type, type()),
          "Configuration model_name is not set",
          request_payload
        )

      true ->
        Api.stream_generate(
          %{
            base_url: base_url,
            api_key: api_key,
            request_payload: request_payload,
            timeout_ms: Map.get(opts, :timeout_ms, 300_000)
          },
          emit
        )
    end
  end

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

  defp maybe_apply_followup_cache_control(raw_request, context) when is_map(context) do
    cache_control_enabled = Map.get(context, :cache_control_enabled, false)
    history_length = Map.get(context, :history_length)

    if cache_control_enabled == true and is_integer(history_length) and history_length >= 0 do
      Payload.apply_followup_cache_control(raw_request, history_length)
    else
      raw_request
    end
  end

  defp assistant_message(%{"content" => content}, _runtime_step) when is_list(content) do
    %{"role" => "assistant", "content" => content}
  end

  defp assistant_message(%{content: content}, _runtime_step) when is_list(content) do
    %{"role" => "assistant", "content" => content}
  end

  defp assistant_message(_raw_response, %RuntimeTrace.Step{} = runtime_step) do
    answer = RuntimeTrace.text_for_item_type(runtime_step, :answer)

    content =
      if String.trim(answer) == "" do
        []
      else
        [%{"type" => "text", "text" => answer}]
      end

    if content == [] do
      nil
    else
      %{"role" => "assistant", "content" => content}
    end
  end

  defp apply_tool_results(%RuntimeTrace.Step{} = runtime_step, results) when is_list(results) do
    blocks =
      Enum.map(results, fn result ->
        %{
          "type" => "tool_result",
          "tool_use_id" => result.call_id,
          "content" => Payload.tool_result_content(result.text, result.media_contents)
        }
      end)

    runtime_step =
      Enum.reduce(results, runtime_step, fn result, step ->
        key = "tr:" <> to_string(result.call_id)

        opaque = %{
          "tool_call_id" => result.call_id,
          "name" => result.name,
          "raw" => result.result_raw
        }

        step
        |> RuntimeTrace.apply_event({:ensure_item, key, :tool_result, nil})
        |> RuntimeTrace.apply_event(
          {:set_text, key, :tool_result, 1, to_string(result.text || "")}
        )
        |> RuntimeTrace.apply_event({:set_opaque, key, :tool_result, @opaque_sequence, opaque})
        |> TraceHelpers.apply_media_contents_to_trace(
          key,
          :tool_result,
          Map.get(result, :media_contents, [])
        )
        |> TraceHelpers.apply_artifacts_to_trace(result)
      end)

    message =
      if blocks == [] do
        nil
      else
        %{"role" => "user", "content" => blocks}
      end

    {message, runtime_step}
  end

  defp apply_tool_results(runtime_step, _results), do: {nil, runtime_step}
end
