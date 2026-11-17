defmodule IntellectualClub.Tools.Lua.Codec do
  @moduledoc """
  Strict JSON boundary for Lua 1.0.2. Only this adapter depends on VM table layout.
  Collection tags live in VM-private storage, not user-editable metatables.
  """
  alias Lua.VM.{State, Table}
  alias IntellectualClub.Tools.Lua.{Host, Limits}

  def install(lua) do
    {null, state} = State.alloc_userdata(lua.state, :json_null)

    lua =
      %{lua | state: state}
      |> Lua.put_private(:json_null, null)
      |> Lua.put_private(:json_kinds, %{})

    lua
    |> Lua.set!(["json", "null"], null)
    |> Host.set(["json", "array"], fn args, lua -> collection(args, lua, :array) end)
    |> Host.set(["json", "object"], fn args, lua -> collection(args, lua, :object) end)
    |> Host.set(["json", "encode"], fn
      [value], lua -> {[value |> decode!(lua) |> Jason.encode!()], lua}
      _, _lua -> raise ArgumentError, "json.encode expects one value"
    end)
    |> Host.set(["json", "decode"], fn
      [value], lua when is_binary(value) ->
        if byte_size(value) > Limits.get(:json_bytes),
          do: raise(ArgumentError, "JSON exceeds size limit")

        case Jason.decode(value) do
          {:ok, value} ->
            validate!(value)
            {encoded, lua} = encode(value, lua)
            {[encoded], lua}

          _ ->
            raise ArgumentError, "Invalid JSON"
        end

      _, _lua ->
        raise ArgumentError, "json.decode expects one JSON string"
    end)
  end

  def validate!(value, max_bytes \\ Limits.get(:json_bytes)) do
    validate_value!(value, 0, {Limits.get(:json_nodes), max_bytes})

    value
  end

  def encode(value, lua) when is_map(value) or is_list(value) do
    {pairs, lua} =
      value
      |> pairs()
      |> Enum.map_reduce(lua, fn {key, value}, lua ->
        {value, lua} = encode(value, lua)
        {{key, value}, lua}
      end)

    {ref, state} = State.alloc_table(lua.state, Map.new(pairs))
    kind = if is_map(value), do: :object, else: :array
    {ref, tag(%{lua | state: state}, ref, kind)}
  end

  def encode(nil, lua), do: {Lua.get_private!(lua, :json_null), lua}

  def encode(value, lua) when is_binary(value) or is_number(value) or is_boolean(value),
    do: {value, lua}

  def decode!(value, lua) do
    {value, _remaining} = decode(value, lua, MapSet.new(), 0, Limits.get(:json_nodes))
    validate!(value)
  end

  def field(lua, {:tref, _} = ref, key), do: lua.state |> State.get_table(ref) |> Table.get(key)
  def field(_lua, _other, _key), do: raise(ArgumentError, "Expected a Lua table")

  defp pairs(value) when is_map(value), do: Map.to_list(value)

  defp pairs(value) when is_list(value),
    do: value |> Enum.with_index(1) |> Enum.map(fn {v, i} -> {i, v} end)

  defp collection([], lua, kind) do
    {ref, state} = State.alloc_table(lua.state)
    {[ref], tag(%{lua | state: state}, ref, kind)}
  end

  defp collection([{:tref, _} = ref], lua, kind), do: {[ref], tag(lua, ref, kind)}

  defp collection(_, _lua, _kind),
    do: raise(ArgumentError, "json.array/object expects a table or no arguments")

  defp tag(lua, ref, kind),
    do: Lua.put_private(lua, :json_kinds, Map.put(Lua.get_private!(lua, :json_kinds), ref, kind))

  defp decode(_value, _lua, _seen, depth, remaining) when depth > 32 or remaining <= 0,
    do: raise(ArgumentError, "JSON exceeds depth or element limit")

  defp decode({:tref, _} = ref, lua, seen, depth, remaining) do
    if depth > Limits.get(:json_depth) or MapSet.member?(seen, ref),
      do: raise(ArgumentError, "JSON contains a cycle or exceeds depth limit")

    data = lua.state |> State.get_table(ref) |> Table.to_map()
    if map_size(data) >= remaining, do: raise(ArgumentError, "JSON exceeds element limit")
    kind = Map.get(Lua.get_private!(lua, :json_kinds), ref)
    keys = Map.keys(data)
    array? = kind == :array or (kind != :object and keys != [] and Enum.all?(keys, &is_integer/1))

    if array? and Enum.sort(keys) != Enum.to_list(1..map_size(data)//1),
      do: raise(ArgumentError, "JSON arrays must have consecutive keys starting at 1")

    if not array? and not Enum.all?(keys, &is_binary/1),
      do: raise(ArgumentError, "JSON objects require string keys")

    seen = MapSet.put(seen, ref)

    {pairs, remaining} =
      Enum.map_reduce(data, remaining - 1, fn {key, value}, count ->
        {value, count} = decode(value, lua, seen, depth + 1, count - if(array?, do: 0, else: 1))
        {{key, value}, count}
      end)

    value =
      if array?,
        do: pairs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)),
        else: Map.new(pairs)

    {value, remaining}
  end

  defp decode({:udref, _} = ref, lua, _seen, _depth, remaining) do
    if ref != Lua.get_private!(lua, :json_null),
      do: raise(ArgumentError, "JSON cannot contain userdata")

    {nil, remaining - 1}
  end

  defp decode(value, _lua, _seen, _depth, remaining)
       when is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value),
       do: {value, remaining - 1}

  defp decode(_, _lua, _seen, _depth, _remaining),
    do: raise(ArgumentError, "JSON cannot contain functions or non-JSON values")

  # Account for encoded bytes before constructing the complete JSON binary.
  # Repeated references to one small string must not expand into a huge output.
  defp validate_value!(_value, depth, {nodes, bytes}) when depth > 32 or nodes <= 0 or bytes < 0,
    do: raise(ArgumentError, "JSON exceeds depth, element or size limit")

  defp validate_value!(value, depth, {nodes, bytes})
       when is_map(value) and not is_struct(value) do
    overhead = 2 + max(2 * map_size(value) - 1, 0)

    Enum.reduce(value, budget!(nodes - 1, bytes - overhead), fn {key, value}, budget ->
      unless is_binary(key), do: raise(ArgumentError, "JSON object keys must be UTF-8 strings")
      budget = validate_value!(key, depth + 1, budget)
      validate_value!(value, depth + 1, budget)
    end)
  end

  defp validate_value!(value, depth, {nodes, bytes}) when is_list(value) do
    {budget, _first} =
      Enum.reduce(value, {budget!(nodes - 1, bytes - 2), true}, fn value,
                                                                   {{nodes, bytes}, first} ->
        budget = validate_value!(value, depth + 1, {nodes, bytes - if(first, do: 0, else: 1)})
        {budget, false}
      end)

    budget
  end

  defp validate_value!(value, _depth, {nodes, bytes}) when is_binary(value) do
    unless String.valid?(value) and byte_size(value) <= bytes,
      do: raise(ArgumentError, "JSON strings must be bounded UTF-8")

    budget!(nodes - 1, bytes - IO.iodata_length(Jason.encode_to_iodata!(value)))
  end

  defp validate_value!(value, _depth, {nodes, bytes})
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: budget!(nodes - 1, bytes - IO.iodata_length(Jason.encode_to_iodata!(value)))

  defp validate_value!(_, _, _), do: raise(ArgumentError, "Value is not JSON-compatible")

  defp budget!(nodes, bytes) when nodes >= 0 and bytes >= 0, do: {nodes, bytes}
  defp budget!(_, _), do: raise(ArgumentError, "JSON exceeds element or size limit")
end
