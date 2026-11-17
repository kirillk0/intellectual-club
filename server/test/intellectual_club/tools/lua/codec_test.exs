defmodule IntellectualClub.Tools.Lua.CodecTest do
  use ExUnit.Case, async: false
  import IntellectualClub.TestEnv
  alias IntellectualClub.Tools.Lua.Codec

  test "arrays have the same element budget entering and leaving Lua" do
    put_app_env(:lua_tool_limits, json_nodes: 7)
    value = [1, 2, 3, 4, 5, 6]
    assert Codec.validate!(value) == value
    {ref, lua} = Codec.encode(value, Codec.install(Lua.new()))
    assert Codec.decode!(ref, lua) == value
    assert_raise ArgumentError, fn -> Codec.validate!(value ++ [7]) end
  end

  test "aggregate JSON bytes are bounded before allocating the complete encoded result" do
    value = List.duplicate(String.duplicate("x", 16_000), 1_000)
    assert_raise ArgumentError, fn -> Codec.validate!(value) end

    for value <- [%{}, [], %{"\"" => "\n"}, [true, nil, 42, "Привет"]] do
      size = byte_size(Jason.encode!(value))
      assert Codec.validate!(value, size) == value
      assert_raise ArgumentError, fn -> Codec.validate!(value, size - 1) end
    end
  end

  test "larger HTTP envelopes retain JSON depth and element bounds" do
    assert_raise ArgumentError, fn ->
      Codec.validate!(%{"json" => Enum.reduce(1..40, nil, fn _, value -> [value] end)}, 2_200_000)
    end

    assert_raise ArgumentError, fn -> Codec.validate!(List.duplicate(0, 40_000), 2_200_000) end
    value = %{"body" => String.duplicate("x", 300_000)}
    assert Codec.validate!(value, 2_200_000) == value
    assert_raise ArgumentError, fn -> Codec.validate!(value) end
  end
end
