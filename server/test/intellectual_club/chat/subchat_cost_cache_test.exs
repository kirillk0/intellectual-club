defmodule IntellectualClub.Chat.SubchatCostCacheTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Chat.SubchatCostCache

  setup do
    cache = start_supervised!({SubchatCostCache, name: __MODULE__.Cache})
    %{cache: cache}
  end

  test "nil is cached and actor identities and revisions are separate", %{cache: cache} do
    owner = {{:actor, 1}, 12}
    reader = {{:actor, 2}, 12}
    loader = fn keys -> Map.new(keys, &{&1, nil}) end
    never = fn _keys -> flunk("unchanged snapshots must not reload") end

    assert %{^owner => nil} =
             SubchatCostCache.fetch_many(%{owner => :phase_one}, loader, cache: cache)

    assert %{^owner => nil} =
             SubchatCostCache.fetch_many(%{owner => :phase_one}, never, cache: cache)

    zero = fn keys -> Map.new(keys, &{&1, 0.0}) end

    assert %{^reader => +0.0} =
             SubchatCostCache.fetch_many(%{reader => :phase_one}, zero, cache: cache)

    assert %{^owner => nil} =
             SubchatCostCache.fetch_many(%{owner => :phase_one}, never, cache: cache)

    assert %{^owner => +0.0} =
             SubchatCostCache.fetch_many(%{owner => :phase_two}, zero, cache: cache)
  end

  test "concurrent misses share one loader and values outlive the request", %{cache: cache} do
    tasks = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    test_pid = self()
    requests = %{message: :phase}

    first =
      Task.Supervisor.async_nolink(tasks, fn ->
        SubchatCostCache.fetch_many(
          requests,
          fn [:message] ->
            send(test_pid, {:loading, self()})

            receive do
              :finish -> %{message: 0.02}
            end
          end,
          cache: cache
        )
      end)

    assert_receive {:loading, loader_pid}

    second =
      Task.Supervisor.async_nolink(tasks, fn ->
        send(test_pid, :second_request)
        SubchatCostCache.fetch_many(requests, fn _ -> flunk("duplicate loader") end, cache: cache)
      end)

    assert_receive :second_request
    send(loader_pid, :finish)
    assert Task.await(first) == %{message: 0.02}
    assert Task.await(second) == %{message: 0.02}

    assert SubchatCostCache.fetch_many(requests, fn _ -> flunk("request-owned cache") end,
             cache: cache
           ) ==
             %{message: 0.02}
  end

  test "failed or terminated loaders release their reservations", %{cache: cache} do
    requests = %{message: :phase}

    assert_raise RuntimeError, "failed aggregate", fn ->
      SubchatCostCache.fetch_many(requests, fn _ -> raise "failed aggregate" end, cache: cache)
    end

    tasks = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    test_pid = self()

    {:ok, owner} =
      Task.Supervisor.start_child(tasks, fn ->
        SubchatCostCache.fetch_many(
          requests,
          fn _ ->
            send(test_pid, :reserved)

            receive do
              :finish -> %{message: nil}
            end
          end,
          cache: cache
        )
      end)

    assert_receive :reserved
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert SubchatCostCache.fetch_many(requests, fn _ -> %{message: 0.01} end, cache: cache) ==
             %{message: 0.01}
  end

  test "explicit refresh bypasses an otherwise unchanged snapshot", %{cache: cache} do
    requests = %{message: :phase}
    SubchatCostCache.fetch_many(requests, fn _ -> %{message: nil} end, cache: cache)

    assert SubchatCostCache.fetch_many(requests, fn _ -> %{message: 0.03} end,
             cache: cache,
             refresh?: true
           ) == %{message: 0.03}
  end

  test "entry count and safety expiry are bounded" do
    bounded =
      start_supervised!({SubchatCostCache, name: __MODULE__.Bounded, max_entries: 2},
        id: :bounded
      )

    loader = fn keys -> Map.new(keys, &{&1, 0.0}) end

    SubchatCostCache.fetch_many(%{one: :phase, two: :phase, three: :phase}, loader,
      cache: bounded
    )

    assert map_size(:sys.get_state(bounded).entries) == 2

    expired =
      start_supervised!({SubchatCostCache, name: __MODULE__.Expired, ttl_ms: 0}, id: :expired)

    SubchatCostCache.fetch_many(%{one: :phase}, loader, cache: expired)

    assert SubchatCostCache.fetch_many(%{one: :phase}, fn _ -> %{one: nil} end, cache: expired) ==
             %{one: nil}
  end
end
