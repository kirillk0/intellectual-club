defmodule IntellectualClub.HttpClient do
  @moduledoc """
  Request options for Req's automatically managed HTTP pools.

  Req replaces explicit Finch options rather than merging them with its defaults.
  Preserve the shared pool settings when a request needs a custom connect timeout.
  """

  @spec finch_options(non_neg_integer()) :: keyword()
  def finch_options(connect_timeout_ms)
      when is_integer(connect_timeout_ms) and connect_timeout_ms >= 0 do
    options = Keyword.fetch!(Req.default_options(), :finch)
    put_in(options, [:conn_opts, :transport_opts, :timeout], connect_timeout_ms)
  end
end
