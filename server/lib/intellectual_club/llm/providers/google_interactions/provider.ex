defmodule IntellectualClub.Llm.Providers.GoogleInteractions do
  @moduledoc """
  Google Interactions API provider package.
  """

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.Common.AuthValidation
  alias IntellectualClub.Llm.Providers.Common.TraceHelpers
  alias IntellectualClub.Llm.Providers.GoogleInteractions.Api
  alias IntellectualClub.Llm.Providers.GoogleInteractions.ModelDiscovery
  alias IntellectualClub.Llm.Providers.GoogleInteractions.Payload

  @type_id "google_interactions"
  @google_v1_base_url "https://generativelanguage.googleapis.com/v1"
  @google_v1beta_base_url "https://generativelanguage.googleapis.com/v1beta"
  @opaque_sequence 10_000

  @impl true
  def type, do: @type_id

  @impl true
  def label, do: "Google Interactions API"

  @impl true
  def metadata do
    %{
      type: type(),
      label: label(),
      default_auth_method: "api_key",
      auth_methods: [
        %{value: "api_key", label: "API key", credential: "api_key", required: true}
      ],
      base_url_options: [@google_v1_base_url, @google_v1beta_base_url],
      default_base_url: @google_v1_base_url,
      supports_model_discovery: true
    }
  end

  @impl true
  def validate_provider(provider, opts) do
    AuthValidation.validate(provider, Keyword.put(opts, :metadata, metadata()))
  end

  @impl true
  def list_models(provider) do
    ModelDiscovery.list_models(provider)
  end

  @impl true
  def supports_cache_control?, do: false

  @impl true
  def build_initial_request(opts) when is_map(opts) do
    input_steps =
      Payload.build_input_steps(Map.get(opts, :history, []),
        supports_image_input: Map.get(opts, :supports_image_input, false),
        provider_type: type()
      )

    raw_request =
      Payload.build_interaction_payload(
        Map.get(opts, :model_name),
        Map.get(opts, :parameters, %{}) || %{},
        input_steps,
        system_instruction: Map.get(opts, :system_prompt),
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

    {function_result_steps, runtime_step} =
      apply_tool_results_to_trace(runtime_step, Map.get(opts, :results, []), context)

    input_steps =
      Payload.previous_input_steps(previous_raw_request) ++
        Payload.response_steps(runtime_step.raw_response) ++ function_result_steps

    raw_request =
      Payload.build_interaction_payload(
        RequestPayload.model_name(previous_raw_request, Map.get(context, :model_name)),
        Payload.parameters_from_request(previous_raw_request, Map.get(context, :parameters, %{})),
        input_steps,
        system_instruction:
          previous_raw_request
          |> Map.get("system_instruction", Map.get(context, :system_prompt))
          |> to_string(),
        tools: followup_tools_from_request(previous_raw_request, Map.get(opts, :tools, []))
      )

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

  defp followup_tools_from_request(previous_raw_request, tools)
       when is_map(previous_raw_request) do
    configured_tools =
      previous_raw_request
      |> Map.get("tools")
      |> case do
        value when is_list(value) -> value
        _other -> []
      end

    Payload.google_tools(configured_tools ++ normalize_tools_list(tools))
  end

  defp normalize_tools_list(tools) when is_list(tools), do: tools
  defp normalize_tools_list(_tools), do: []

  defp apply_tool_results_to_trace(%RuntimeTrace.Step{} = runtime_step, results, context)
       when is_list(results) and is_map(context) do
    opts = [
      supports_image_input: Map.get(context, :supports_image_input, false),
      provider_type: type()
    ]

    function_result_steps = Enum.map(results, &Payload.function_result_step(&1, opts))

    runtime_step =
      Enum.zip(function_result_steps, results)
      |> Enum.reduce(runtime_step, fn {function_result_step, result}, step ->
        call_id = result_value(result, :call_id) |> to_string()
        key = "tr:" <> call_id
        output_text = result_value(result, :text) |> to_string()

        opaque = %{
          "google_interaction_step" => function_result_step,
          "tool_call_id" => call_id,
          "call_id" => call_id,
          "tool_call_item_id" => result_value(result, :tool_call_item_id),
          "name" => result_value(result, :name),
          "raw" => result_value(result, :result_raw)
        }

        step
        |> RuntimeTrace.apply_event({:ensure_item, key, :tool_result, nil})
        |> RuntimeTrace.apply_event({:set_text, key, :tool_result, 1, output_text})
        |> RuntimeTrace.apply_event({:set_opaque, key, :tool_result, @opaque_sequence, opaque})
        |> TraceHelpers.apply_media_contents_to_trace(
          key,
          :tool_result,
          result_value(result, :media_contents)
        )
        |> TraceHelpers.apply_artifacts_to_trace(result)
      end)

    {function_result_steps, runtime_step}
  end

  defp result_value(%{} = result, key) when is_atom(key) do
    Map.get(result, key, Map.get(result, Atom.to_string(key)))
  end

  defp result_value(_result, :media_contents), do: []
  defp result_value(_result, _key), do: nil
end
