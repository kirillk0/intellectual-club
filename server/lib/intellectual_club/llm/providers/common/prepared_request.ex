defmodule IntellectualClub.Llm.Providers.Common.PreparedRequest do
  @moduledoc """
  Finalizes logical provider requests before a new generation step is persisted.

  Preparation is deterministic and idempotent for the same context. Transport
  envelopes, headers, credentials and image hydration do not belong here.
  Senders receive the prepared request unchanged.
  """

  alias IntellectualClub.Generation.RequestPayload

  @spec prepare(module(), map(), map()) :: map()
  def prepare(adapter, request, context)
      when is_atom(adapter) and is_map(request) and is_map(context) do
    request = RequestPayload.stringify_keys(request)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :prepare_request, 2) do
      adapter.prepare_request(request, context)
    else
      request
    end
  end
end
