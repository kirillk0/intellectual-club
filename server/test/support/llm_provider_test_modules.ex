defmodule IntellectualClub.TestSupport.LlmProviders.SelfContainedTestProvider do
  @moduledoc false

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  @impl true
  def type, do: "self_contained_test_provider"

  @impl true
  def label, do: "Self-contained test provider"

  @impl true
  def metadata do
    %{
      type: type(),
      label: label(),
      default_auth_method: "api_key",
      auth_methods: [
        %{value: "api_key", label: "API key", credential: "api_key", required: true}
      ],
      base_url_options: [],
      default_base_url: nil,
      supports_model_discovery: false
    }
  end

  @impl true
  def validate_provider(_provider, _opts), do: :ok

  @impl true
  def list_models(_provider), do: {:ok, []}

  @impl true
  def supports_cache_control?, do: false

  @impl true
  def build_initial_request(_opts) do
    %{raw_request: %{}, request_snapshot: request_snapshot(%{})}
  end

  @impl true
  def build_followup_request(opts) do
    %{
      runtime_step: Map.fetch!(opts, :runtime_step),
      raw_request: %{},
      request_snapshot: request_snapshot(%{})
    }
  end

  @impl true
  def request_snapshot(_raw_request),
    do: %{model_input: [], system_prompt: "", history_length: nil}

  @impl true
  def stream_generate(_opts, _emit), do: :ok
end
