defmodule IntellectualClub.Llm.Providers.Common.RegistryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.Common.Registry

  defmodule DuplicateA do
    def type, do: "duplicate_test"
    def label, do: "Duplicate A"
    def metadata, do: base_metadata(label())
    def validate_provider(_provider, _opts), do: :ok
    def list_models(_provider), do: {:ok, []}
    def supports_cache_control?, do: false

    def build_initial_request(_opts),
      do: %{raw_request: %{}, request_snapshot: request_snapshot(%{})}

    def build_followup_request(opts),
      do: %{
        runtime_step: opts.runtime_step,
        raw_request: %{},
        request_snapshot: request_snapshot(%{})
      }

    def request_snapshot(_raw_request),
      do: %{model_input: [], system_prompt: "", history_length: nil}

    def stream_generate(_opts, _emit), do: :ok

    defp base_metadata(label) do
      %{
        type: type(),
        label: label,
        default_auth_method: "api_key",
        auth_methods: [],
        base_url_options: [],
        default_base_url: nil,
        supports_model_discovery: false
      }
    end
  end

  defmodule DuplicateB do
    def type, do: "duplicate_test"
    def label, do: "Duplicate B"
    def metadata, do: DuplicateA.metadata()
    def validate_provider(_provider, _opts), do: :ok
    def list_models(_provider), do: {:ok, []}
    def supports_cache_control?, do: false

    def build_initial_request(_opts),
      do: %{raw_request: %{}, request_snapshot: request_snapshot(%{})}

    def build_followup_request(opts),
      do: %{
        runtime_step: opts.runtime_step,
        raw_request: %{},
        request_snapshot: request_snapshot(%{})
      }

    def request_snapshot(_raw_request),
      do: %{model_input: [], system_prompt: "", history_length: nil}

    def stream_generate(_opts, _emit), do: :ok
  end

  test "auto-discovers compiled provider modules" do
    assert {:ok, IntellectualClub.TestSupport.LlmProviders.SelfContainedTestProvider} =
             Registry.fetch("self_contained_test_provider")
  end

  test "returns controlled error for unknown provider types" do
    assert Registry.fetch("unknown_provider_type") == {:error, :unknown_provider_type}
  end

  test "rejects duplicate provider type ids" do
    assert_raise ArgumentError, ~r/Duplicate LLM provider type "duplicate_test"/, fn ->
      Registry.build_index([DuplicateA, DuplicateB])
    end
  end
end
