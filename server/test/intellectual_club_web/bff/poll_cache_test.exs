defmodule IntellectualClubWeb.Bff.PollCacheTest do
  use ExUnit.Case, async: false

  alias IntellectualClubWeb.Bff.PollCache

  setup do
    if is_nil(Process.whereis(PollCache)), do: start_supervised!(PollCache)
    %{key: make_ref()}
  end

  test "values reuse only the same identity and content revision", %{key: key} do
    owner = self()

    loader = fn ->
      assert self() == owner
      send(owner, :loaded)
      %{content: "original"}
    end

    assert PollCache.fetch({key, :actor_one}, "r1", loader) == %{content: "original"}
    assert_receive :loaded
    assert PollCache.fetch({key, :actor_one}, "r1", loader) == %{content: "original"}
    refute_received :loaded
    PollCache.fetch({key, :actor_one}, "r2", loader)
    assert_receive :loaded
    PollCache.fetch({key, :actor_two}, "r2", loader)
    assert_receive :loaded
  end

  test "oversized values are returned without occupying the bounded cache", %{key: key} do
    owner = self()
    value = String.duplicate("x", 2 * 1024 * 1024 + 1)

    loader = fn ->
      send(owner, :loaded)
      value
    end

    assert PollCache.fetch(key, "same", loader) == value
    assert_receive :loaded
    assert PollCache.fetch(key, "same", loader) == value
    assert_receive :loaded
  end
end
