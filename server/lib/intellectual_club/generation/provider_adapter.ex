defmodule IntellectualClub.Generation.ProviderAdapter do
  @moduledoc """
  Behaviour for protocol-specific generation adapters.

  Adapters own request construction, follow-up reconstruction after tool
  execution, retry snapshots, and provider streaming.
  """

  alias IntellectualClub.Generation.RuntimeTrace

  @type request_snapshot :: %{
          required(:model_input) => list(),
          required(:system_prompt) => String.t()
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

  @callback supports_cache_control?() :: boolean()
  @callback build_initial_request(map()) :: initial_request_result()
  @callback build_followup_request(map()) :: followup_request_result()
  @callback request_snapshot(map()) :: request_snapshot()
  @callback stream_generate(map(), (term() -> any())) :: :ok
end
