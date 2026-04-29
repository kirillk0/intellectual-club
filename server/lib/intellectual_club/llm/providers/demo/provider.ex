defmodule IntellectualClub.Llm.Providers.Demo do
  @moduledoc """
  Local demo provider package.
  """

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  alias IntellectualClub.Llm.Providers.Demo.Trace
  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Llm.Providers.Common.AuthValidation
  alias IntellectualClub.Llm.Providers.Common.ChatAdapterHelpers

  @type_id "demo"

  @impl true
  def type, do: @type_id

  @impl true
  def label, do: "Demo"

  @impl true
  def metadata do
    %{
      type: type(),
      label: label(),
      default_auth_method: "api_key",
      auth_methods: [
        %{value: "api_key", label: "API key", credential: nil, required: false}
      ],
      base_url_options: [],
      default_base_url: nil,
      supports_model_discovery: false
    }
  end

  @impl true
  def validate_provider(provider, opts) do
    AuthValidation.validate(provider, Keyword.put(opts, :metadata, metadata()))
  end

  @impl true
  def list_models(_provider), do: {:ok, []}

  @impl true
  def supports_cache_control?, do: false

  @impl true
  def build_initial_request(opts) when is_map(opts) do
    messages =
      ChatAdapterHelpers.build_initial_messages(
        opts
        |> Map.put(:provider_type, type())
        |> Map.put(:cache_control_enabled, false)
      )

    raw_request = %{"messages" => messages}

    %{
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def build_followup_request(opts) when is_map(opts) do
    followup =
      ChatAdapterHelpers.build_followup_messages(
        opts
        |> Map.put(:provider_type, type())
        |> Map.put(:cache_control_enabled, false)
      )

    raw_request = %{"messages" => followup.messages}

    %{
      runtime_step: followup.runtime_step,
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def request_snapshot(raw_request), do: ChatAdapterHelpers.request_snapshot(raw_request)

  @impl true
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    request_payload =
      opts
      |> Map.get(:request_payload, %{})
      |> RequestPayload.stringify_keys()

    Trace.stream_generate(
      %{
        request_payload: request_payload,
        chunk_delay_ms: Map.get(opts, :chunk_delay_ms, 40)
      },
      emit
    )
  end
end
