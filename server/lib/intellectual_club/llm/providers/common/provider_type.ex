defmodule IntellectualClub.Llm.Providers.Common.ProviderType do
  @moduledoc """
  Behaviour for self-contained LLM provider type packages.
  """

  alias IntellectualClub.Generation.RuntimeTrace

  @type request_snapshot :: %{
          required(:model_input) => list(),
          required(:system_prompt) => String.t(),
          optional(:history_length) => integer() | nil
        }

  @type initial_request_result :: %{
          required(:raw_request) => map(),
          required(:request_snapshot) => request_snapshot()
        }

  @type followup_request_result :: %{
          required(:runtime_step) => RuntimeTrace.Step.t(),
          required(:raw_request) => map(),
          required(:request_snapshot) => request_snapshot()
        }

  @type auth_method_metadata :: %{
          required(:value) => String.t(),
          required(:label) => String.t(),
          optional(:credential) => String.t() | nil,
          optional(:required) => boolean()
        }

  @type metadata :: %{
          required(:type) => String.t(),
          required(:label) => String.t(),
          required(:default_auth_method) => String.t(),
          required(:auth_methods) => [auth_method_metadata()],
          required(:base_url_options) => [String.t()],
          required(:default_base_url) => String.t() | nil,
          required(:supports_model_discovery) => boolean()
        }

  @type model_option :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:context_length) => integer() | nil,
          required(:supports_image_input) => boolean() | nil
        }

  @callback type() :: String.t()
  @callback label() :: String.t()
  @callback metadata() :: metadata()
  @callback validate_provider(map(), keyword()) :: :ok | {:error, keyword(String.t())}
  @callback list_models(map()) :: {:ok, [model_option()]} | {:error, String.t()}

  @callback supports_cache_control?() :: boolean()
  @callback build_initial_request(map()) :: initial_request_result()
  @callback build_followup_request(map()) :: followup_request_result()
  @callback request_snapshot(map()) :: request_snapshot()
  @callback stream_generate(map(), (term() -> any())) :: :ok

  @callback start_session(map()) :: {:ok, term()} | :ignore | {:error, term()}
  @callback stop_session(term()) :: :ok

  @optional_callbacks start_session: 1, stop_session: 1
end
