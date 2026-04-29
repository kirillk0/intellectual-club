defmodule IntellectualClub.Llm.Providers.Common.MissingProvider do
  @moduledoc false

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  @impl true
  def type, do: "missing"

  @impl true
  def label, do: "Missing provider"

  @impl true
  def metadata do
    %{
      type: type(),
      label: label(),
      default_auth_method: "api_key",
      auth_methods: [],
      base_url_options: [],
      default_base_url: nil,
      supports_model_discovery: false
    }
  end

  @impl true
  def validate_provider(_provider, _opts), do: {:error, type: "is not available"}

  @impl true
  def list_models(_provider), do: {:error, "Provider type is not available."}

  @impl true
  def supports_cache_control?, do: false

  @impl true
  def build_initial_request(opts) when is_map(opts) do
    raw_request = %{
      "error" => provider_error_text(Map.get(opts, :provider_type))
    }

    %{
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def build_followup_request(opts) when is_map(opts) do
    runtime_step = Map.fetch!(opts, :runtime_step)
    raw_request = Map.get(runtime_step, :raw_request) || %{}

    %{
      runtime_step: runtime_step,
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def request_snapshot(_raw_request),
    do: %{model_input: [], system_prompt: "", history_length: nil}

  @impl true
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    context = Map.get(opts, :context, %{})
    provider_type = Map.get(context, :provider_type)
    request_payload = Map.get(opts, :request_payload, %{})

    emit.(
      {:response_error,
       %{
         provider: provider_type,
         error_kind: "configuration",
         retryable: false,
         error_text: provider_error_text(provider_type),
         raw_request: request_payload,
         raw_response: nil
       }}
    )

    :ok
  end

  defp provider_error_text(type) do
    "Provider type is not available: #{to_string(type || "")}"
  end
end
