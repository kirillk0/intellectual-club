defmodule IntellectualClub.Llm.Providers.Responses.HttpPool do
  @moduledoc """
  Dedicated Finch pool for long-lived Responses API streams.

  Finch applies the default pool configuration independently to every origin and
  opens HTTP/1 connections lazily, up to the configured limit.
  """

  @config_key :responses_http_pool

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Finch.child_spec(
      name: __MODULE__,
      pools: %{
        default: [
          size: pool_size(),
          count: 1,
          conn_opts: [transport_opts: [timeout: connect_timeout_ms()]]
        ]
      }
    )
  end

  @doc false
  @spec req_options(non_neg_integer()) :: keyword()
  def req_options(connect_timeout_ms)
      when is_integer(connect_timeout_ms) and connect_timeout_ms >= 0 do
    if connect_timeout_ms == connect_timeout_ms() do
      [finch: __MODULE__]
    else
      [connect_options: [timeout: connect_timeout_ms]]
    end
  end

  @doc false
  @spec pool_size() :: pos_integer()
  def pool_size do
    config_value!(:size)
  end

  @doc false
  @spec connect_timeout_ms() :: pos_integer()
  def connect_timeout_ms do
    config_value!(:connect_timeout_ms)
  end

  defp config_value!(key) do
    value =
      :intellectual_club
      |> Application.fetch_env!(@config_key)
      |> Keyword.fetch!(key)

    if is_integer(value) and value > 0 do
      value
    else
      raise ArgumentError,
            "expected #{inspect(@config_key)} #{inspect(key)} to be a positive integer, " <>
              "got: #{inspect(value)}"
    end
  end
end
