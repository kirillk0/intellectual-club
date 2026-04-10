defmodule IntellectualClub.Generation.Adapters.DemoAdapter do
  @moduledoc false

  @behaviour IntellectualClub.Generation.ProviderAdapter

  alias IntellectualClub.Generation.Adapters.ChatAdapterHelpers
  alias IntellectualClub.Generation.DemoStreamTrace
  alias IntellectualClub.Generation.RequestPayload

  @impl true
  def supports_cache_control?, do: false

  @impl true
  def build_initial_request(opts) when is_map(opts) do
    messages =
      ChatAdapterHelpers.build_initial_messages(
        opts
        |> Map.put(:provider_type, :demo)
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
        |> Map.put(:provider_type, :demo)
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

    DemoStreamTrace.stream_generate(
      %{
        request_payload: request_payload,
        chunk_delay_ms: Map.get(opts, :chunk_delay_ms, 40)
      },
      emit
    )
  end
end
