defmodule IntellectualClub.Llm.Providers.ResponsesWss do
  @moduledoc """
  Responses API provider package using WebSocket transport.
  """

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  alias IntellectualClub.Llm.Providers.Responses

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
    |> Map.put(:selectable, false)
  end

  @impl true
  def validate_provider(provider, opts) do
    Responses.validate_provider(provider, opts)
  end

  @impl true
  def list_models(provider), do: Responses.list_models(provider)

  @impl true
  def supports_cache_control?, do: Responses.supports_cache_control?()

  @impl true
  def apply_standard_parameters(parameters, settings),
    do: Responses.apply_standard_parameters(parameters, settings)

  @impl true
  def build_initial_request(opts), do: Responses.build_initial_request(opts)

  @impl true
  def build_followup_request(opts), do: Responses.build_followup_request(opts)

  @impl true
  def inject_steering(raw_request, steering_items, context),
    do: Responses.inject_steering(raw_request, steering_items, context)

  @impl true
  def request_snapshot(raw_request), do: Responses.request_snapshot(raw_request)

  @impl true
  def start_session(context) when is_map(context) do
    Responses.start_session(context)
  end

  @impl true
  def stop_session(session), do: Responses.stop_session(session)

  @impl true
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    Responses.stream_generate(opts, emit)
  end
end
