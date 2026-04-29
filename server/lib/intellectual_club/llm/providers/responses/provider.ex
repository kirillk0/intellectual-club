defmodule IntellectualClub.Llm.Providers.Responses do
  @moduledoc """
  Responses API provider package.
  """

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Llm.Providers.Common.TraceHelpers
  alias IntellectualClub.Llm.Providers.Common.RequestBuilder
  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Auth
  alias IntellectualClub.Llm.Providers.Common.AuthValidation
  alias IntellectualClub.Llm.Providers.Common.ModelDiscovery
  alias IntellectualClub.Llm.Providers.Responses.Api
  alias IntellectualClub.Llm.Providers.Responses.HistoryInput

  @type_id "responses"
  @opaque_sequence 10_000
  @responses_include ["reasoning.encrypted_content"]

  @impl true
  def type, do: @type_id

  @impl true
  def label, do: "Responses API"

  @impl true
  def metadata do
    %{
      type: type(),
      label: label(),
      default_auth_method: "api_key",
      auth_methods: [
        %{value: "api_key", label: "API key", credential: "api_key", required: true},
        %{
          value: "openai_oauth_refresh_token",
          label: "OpenAI OAuth (Refresh token)",
          credential: "oauth_refresh_token",
          required: true
        }
      ],
      base_url_options: ["https://api.openai.com/v1", "https://chatgpt.com/backend-api/codex"],
      default_base_url: "https://api.openai.com/v1",
      supports_model_discovery: true
    }
  end

  @impl true
  def validate_provider(provider, opts) do
    AuthValidation.validate(provider, Keyword.put(opts, :metadata, metadata()))
  end

  @impl true
  def list_models(provider) do
    ModelDiscovery.list_openai_compatible_models(provider,
      query: %{"client_version" => "1.0.0"}
    )
  end

  @impl true
  def supports_cache_control?, do: false

  @impl true
  def build_initial_request(opts) when is_map(opts) do
    input_items =
      HistoryInput.build_input_items(Map.get(opts, :history, []),
        supports_image_input: Map.get(opts, :supports_image_input, false),
        provider_type: type()
      )

    raw_request =
      RequestBuilder.build_responses_payload_from_input_items(
        Map.get(opts, :model_name),
        Map.get(opts, :parameters, %{}) || %{},
        input_items,
        include: @responses_include,
        instructions: Map.get(opts, :system_prompt),
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

    output_items =
      case runtime_step.raw_response do
        %{} = raw -> Map.get(raw, "output") || []
        _other -> []
      end

    sanitized_output_items =
      sanitize_responses_output_items(output_items,
        provider_base_url: Map.get(context, :provider_base_url)
      )

    {fco_items, runtime_step} =
      apply_tool_results_to_trace(runtime_step, Map.get(opts, :results, []))

    media_input_items =
      Enum.flat_map(Map.get(opts, :results, []), fn result ->
        Media.media_followup_input_items(result.media_contents,
          supports_image_input: Map.get(context, :supports_image_input, false),
          provider_type: type()
        )
      end)

    next_input_items =
      RequestPayload.input(previous_raw_request) ++
        sanitized_output_items ++ fco_items ++ media_input_items

    raw_request =
      RequestBuilder.build_responses_payload_from_input_items(
        RequestPayload.model_name(previous_raw_request, Map.get(context, :model_name)),
        RequestPayload.parameters(previous_raw_request, Map.get(context, :parameters, %{})),
        next_input_items,
        include: include_from_request(previous_raw_request),
        instructions:
          RequestPayload.instructions(previous_raw_request) |> fallback_instructions(context),
        tools: Map.get(opts, :tools, [])
      )

    %{
      runtime_step: runtime_step,
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def request_snapshot(raw_request) when is_map(raw_request) do
    payload = RequestPayload.stringify_keys(raw_request)

    %{
      model_input: RequestPayload.input(payload),
      system_prompt: RequestPayload.instructions(payload)
    }
  end

  def request_snapshot(_raw_request), do: %{model_input: [], system_prompt: ""}

  @impl true
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    context = Map.get(opts, :context, %{})

    request_payload =
      opts
      |> Map.get(:request_payload, %{})
      |> RequestPayload.stringify_keys()

    token_result =
      Auth.get_bearer_token(%{
        provider_id: Map.get(context, :provider_id),
        auth_method: Map.get(context, :provider_auth_method),
        api_key: Map.get(context, :provider_api_key),
        oauth_refresh_token: Map.get(context, :provider_oauth_refresh_token)
      })

    case token_result do
      {:ok, token} ->
        Api.stream_generate(
          %{
            base_url: Map.get(context, :provider_base_url),
            api_key: token,
            request_payload: request_payload,
            timeout_ms: Map.get(opts, :timeout_ms, 300_000)
          },
          emit
        )

      {:error, error_text} ->
        emit.(
          {:response_error,
           %{
             provider: Map.get(context, :provider_type, type()),
             error_text: error_text,
             raw_request: request_payload,
             raw_response: nil
           }}
        )

        :ok
    end
  end

  defp fallback_instructions("", context), do: Map.get(context, :system_prompt, "")
  defp fallback_instructions(instructions, _context), do: instructions

  defp include_from_request(payload) when is_map(payload) do
    case RequestPayload.include(payload) do
      [] -> @responses_include
      include -> include
    end
  end

  defp apply_tool_results_to_trace(%RuntimeTrace.Step{} = runtime_step, results)
       when is_list(results) do
    fco_items =
      Enum.map(results, fn result ->
        %{
          "type" => "function_call_output",
          "id" => "fco_" <> Ash.UUID.generate(),
          "call_id" => result.call_id,
          "output" => result.text
        }
      end)

    runtime_step =
      Enum.zip(fco_items, results)
      |> Enum.reduce(runtime_step, fn {fco_item, result}, step ->
        item_id = Map.get(fco_item, "id") |> to_string()
        output_text = Map.get(fco_item, "output") |> to_string()

        opaque = %{
          "responses_item" => fco_item,
          "raw" => result.result_raw
        }

        step
        |> RuntimeTrace.apply_event({:ensure_item, item_id, :tool_result, nil})
        |> RuntimeTrace.apply_event({:set_text, item_id, :tool_result, 1, output_text})
        |> RuntimeTrace.apply_event(
          {:set_opaque, item_id, :tool_result, @opaque_sequence, opaque}
        )
        |> TraceHelpers.apply_media_contents_to_trace(
          item_id,
          :tool_result,
          result.media_contents
        )
        |> TraceHelpers.apply_artifacts_to_trace(result)
      end)

    {fco_items, runtime_step}
  end

  defp sanitize_responses_output_items(output_items, opts)
       when is_list(output_items) and is_list(opts) do
    base_url =
      opts
      |> Keyword.get(:provider_base_url)
      |> to_string()
      |> String.downcase()
      |> String.trim()

    drop_reasoning_ids? = base_url != "" and String.contains?(base_url, "openrouter.ai")

    output_items
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      item = RequestPayload.stringify_keys(item)

      case {drop_reasoning_ids?, Map.get(item, "type"), Map.get(item, "id")} do
        {true, "reasoning", id} when is_binary(id) ->
          if String.starts_with?(id, "rs_") do
            Map.delete(item, "id")
          else
            item
          end

        _other ->
          item
      end
    end)
  end

  defp sanitize_responses_output_items(_other, _opts), do: []
end
