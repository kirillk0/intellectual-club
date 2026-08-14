defmodule IntellectualClub.Llm.Providers.Responses.HttpPoolTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.Responses.HttpPool

  test "starts a named Finch with the configured default pool" do
    assert is_pid(Process.whereis(HttpPool))

    assert %{
             id: HttpPool,
             start:
               {Finch, :start_link,
                [
                  [
                    name: HttpPool,
                    pools: %{
                      default: [
                        size: configured_size,
                        count: 1,
                        conn_opts: [transport_opts: [timeout: configured_timeout]]
                      ]
                    }
                  ]
                ]}
           } = HttpPool.child_spec([])

    assert configured_size == HttpPool.pool_size()
    assert configured_timeout == HttpPool.connect_timeout_ms()
  end

  test "uses the named pool for the standard connection timeout" do
    assert HttpPool.req_options(HttpPool.connect_timeout_ms()) == [finch: HttpPool]
  end

  test "preserves an explicit non-standard connection timeout" do
    assert HttpPool.req_options(1_234) == [connect_options: [timeout: 1_234]]
    assert HttpPool.req_options(0) == [connect_options: [timeout: 0]]
  end
end
