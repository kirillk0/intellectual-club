defmodule IntellectualClub.Tools.Lua.Stdlib do
  @moduledoc """
  Allocation guards for Lua 1.0.2 native helpers whose final binary allocation
  bypasses the VM string limit. Keep signatures, callbacks and metatable reads;
  conservative preflights may reject large intermediate values earlier.
  """
  alias IntellectualClub.Tools.Lua.{Codec, Host, Limits}
  alias Lua.VM.{Executor, State, Value}
  alias Lua.VM.Stdlib.{Pattern, String.Pack}

  def install(lua) do
    lua
    |> wrap("string", "format", &format/3)
    |> wrap("string", "pack", &pack/3)
    |> wrap("string", "gsub", &gsub/3)
    |> Host.set(["table", "concat"], &concat/2)
  end

  defp wrap(lua, library, name, callback) do
    original = Codec.field(lua, State.get_global(lua.state, library), name)
    Host.set(lua, [library, name], fn args, lua -> callback.(args, lua, original) end)
  end

  defp format([fmt | args] = all, lua, original) when is_binary(fmt) do
    # A single conversion consumes one argument. Lua's own width/precision parser
    # caps each at two digits. %q can expand every byte to a four-byte escape.
    estimate =
      byte_size(fmt) +
        Enum.reduce(args, 0, fn arg, n -> n + 4 * byte_size(Value.to_string(arg)) + 512 end)

    check!(estimate, lua)
    Host.call(lua, original, all)
  end

  defp format(args, lua, original), do: Host.call(lua, original, args)

  defp pack([fmt | args] = all, lua, original) when is_binary(fmt) do
    fixed = Regex.replace(~r/s[0-9]*|z/, fmt, "c0")
    # Replacing variable strings changes alignment; reserve maximum alignment,
    # length prefixes and terminators per format byte, plus every argument byte.
    estimate =
      Pack.packsize(fixed) + 16 * byte_size(fmt) +
        Enum.reduce(args, 0, fn arg, n -> n + byte_size(Value.to_string(arg)) end)

    check!(estimate, lua)
    Host.call(lua, original, all)
  end

  defp pack(args, lua, original), do: Host.call(lua, original, args)

  defp gsub([source, pattern, replacement | rest] = all, lua, original)
       when is_binary(source) and is_binary(pattern) and is_binary(replacement) do
    limit =
      case rest do
        [n | _] when is_number(n) -> trunc(n)
        _ -> nil
      end

    {literal_bytes, whole_refs, capture_indices} = replacement_budget(replacement, 0, 0, [])
    # Matched ranges do not overlap. One %0 replaces the consumed range, so
    # its total size is already covered by the source budget, not once per
    # match. Additional %0 references together add at most one source each.
    Pattern.gsub_stateful(
      source,
      pattern,
      fn captures, size ->
        extra =
          Enum.reduce(capture_indices, literal_bytes, fn index, n ->
            n + byte_size(Value.to_string(Enum.at(captures, index, source)))
          end)

        size = size + extra
        check!(size, lua)
        {"", size}
      end,
      byte_size(source) * max(whole_refs, 1),
      limit
    )

    Host.call(lua, original, all)
  end

  defp gsub([source, pattern, replacement | rest], lua, original)
       when is_binary(source) and is_binary(pattern) do
    key = {__MODULE__, make_ref()}
    Process.put(key, byte_size(source))

    try do
      callback = fn args, lua ->
        {value, lua} =
          case replacement do
            {:tref, _} ->
              {Codec.field(lua, replacement, hd(args)), lua}

            _ ->
              {results, lua} = Host.call(lua, replacement, args)
              {List.first(results), lua}
          end

        if is_binary(value) or is_number(value) do
          size = Process.get(key) + byte_size(Value.to_string(value))
          check!(size, lua)
          Process.put(key, size)
        end

        {[value], lua}
      end

      {ref, lua} = Host.encode(lua, callback)
      Host.call(lua, original, [source, pattern, ref | rest])
    after
      Process.delete(key)
    end
  end

  defp gsub(args, lua, original), do: Host.call(lua, original, args)

  defp concat([{:tref, _} = ref | rest], lua) do
    separator = Enum.at(rest, 0, "")
    first = Enum.at(rest, 1, 1)

    {last, state} =
      case Enum.at(rest, 2) do
        nil -> Executor.table_length(ref, lua.state)
        n -> {n, lua.state}
      end

    unless is_binary(separator) and is_integer(first) and is_integer(last),
      do: raise(ArgumentError, "table.concat expects a separator string and integer indices")

    count = max(last - first + 1, 0)
    check!(max(count - 1, 0) * byte_size(separator), lua)

    if count > Limits.get(:json_nodes),
      do: raise(ArgumentError, "table.concat element limit exceeded")

    {pieces, state, _size} =
      Enum.reduce(first..last//1, {[], state, 0}, fn index, {pieces, state, size} ->
        {value, state} = Executor.table_index(ref, index, state)

        unless is_binary(value) or is_number(value),
          do: Host.error!("table.concat requires strings or numbers", %{lua | state: state})

        value = Value.to_string(value)
        size = size + byte_size(value) + if(pieces == [], do: 0, else: byte_size(separator))
        check!(size, %{lua | state: state})
        pieces = if pieces == [], do: [value], else: [value, separator | pieces]
        {pieces, state, size}
      end)

    {[pieces |> Enum.reverse() |> IO.iodata_to_binary()], %{lua | state: state}}
  end

  defp concat(_args, _lua), do: raise(ArgumentError, "table.concat expects a table")

  defp replacement_budget("", literal, whole, captures), do: {literal, whole, captures}

  defp replacement_budget("%%" <> rest, literal, whole, captures),
    do: replacement_budget(rest, literal + 1, whole, captures)

  defp replacement_budget("%0" <> rest, literal, whole, captures),
    do: replacement_budget(rest, literal, whole + 1, captures)

  defp replacement_budget(<<"%", digit, rest::binary>>, literal, whole, captures)
       when digit in ?1..?9,
       do: replacement_budget(rest, literal, whole, [digit - ?1 | captures])

  defp replacement_budget("%" <> _rest, _literal, _whole, _captures),
    do: raise(ArgumentError, "Invalid '%' in replacement string")

  defp replacement_budget(<<_byte, rest::binary>>, literal, whole, captures),
    do: replacement_budget(rest, literal + 1, whole, captures)

  defp check!(size, lua) do
    if size > Limits.get(:max_string_bytes),
      do: Host.error!("Lua string allocation limit exceeded", lua)

    :ok
  end
end
