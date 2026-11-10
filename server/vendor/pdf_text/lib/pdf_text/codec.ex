defmodule PdfText.Codec do
  @moduledoc false
  alias PdfText.Context, as: C
  import Bitwise
  @block_bytes 8192

  def decode(data, dict) do
    filters = List.wrap(dict["Filter"])
    params = List.wrap(dict["DecodeParms"])
    if length(filters) > 8, do: C.fail(:unsupported_filter_chain)
    if filters == [], do: charge(data)

    Enum.with_index(filters)
    |> Enum.reduce(data, fn {filter, i}, bytes ->
      output =
        case filter do
          {:name, name} when name in ["FlateDecode", "Fl"] -> inflate(bytes)
          {:name, name} when name in ["ASCII85Decode", "A85"] -> ascii85(bytes)
          _ -> C.fail(:unsupported_filter)
        end

      predictor(output, Enum.at(params, i) || %{})
    end)
  end

  defp charge(data) do
    C.bound(:stream_bytes, byte_size(data))
    C.tick(:decoded_bytes, byte_size(data))
    data
  end

  defp inflate(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      {acc, _size} = compressed(z, data, [], 0)
      :ok = :zlib.inflateEnd(z)
      IO.iodata_to_binary(Enum.reverse(acc))
    rescue
      _ -> C.fail(:invalid_flate)
    after
      :zlib.close(z)
    end
  end

  defp compressed(_z, <<>>, acc, size), do: {acc, size}

  defp compressed(z, data, acc, size) do
    n = min(byte_size(data), 16_384)
    <<chunk::binary-size(^n), rest::binary>> = data
    {acc, size} = drain(z, chunk, acc, size)
    compressed(z, rest, acc, size)
  end

  defp drain(z, input, acc, size) do
    C.check()
    {status, output} = :zlib.safeInflate(z, input)
    n = IO.iodata_length(output)
    C.bound(:stream_bytes, size + n)
    C.tick(:decoded_bytes, n)
    acc = if n > 0, do: [output | acc], else: acc

    case status do
      :finished -> {acc, size + n}
      :continue -> drain(z, <<>>, acc, size + n)
    end
  end

  defp skip_white(<<c, rest::binary>>) when c in [0, 9, 10, 12, 13, 32], do: skip_white(rest)
  defp skip_white(data), do: data

  defp ascii85(data) do
    data = skip_white(data)

    data =
      case data do
        <<"<~", r::binary>> -> r
        _ -> data
      end

    a85(data, 0, 0, [], <<>>, 0, 0)
  end

  defp a85(data, v, digits, acc, block, size, work) when byte_size(block) == @block_bytes,
    do: a85(data, v, digits, [block | acc], <<>>, size, work)

  defp a85(data, v, digits, acc, block, size, work) do
    if rem(work, 1024) == 0, do: C.check()

    case data do
      <<c, rest::binary>> when c in [0, 9, 10, 12, 13, 32] ->
        a85(rest, v, digits, acc, block, size, work + 1)

      <<"~>", _::binary>> ->
        cond do
          digits == 0 ->
            IO.iodata_to_binary(Enum.reverse([block | acc]))

          digits == 1 ->
            C.fail(:invalid_ascii85)

          true ->
            v = Enum.reduce(1..(5 - digits), v, fn _, n -> n * 85 + 84 end)
            if v > 0xFFFFFFFF, do: C.fail(:invalid_ascii85)
            bytes = binary_part(<<v::32>>, 0, digits - 1)
            C.bound(:stream_bytes, size + byte_size(bytes))
            C.tick(:decoded_bytes, byte_size(bytes))
            IO.iodata_to_binary(Enum.reverse([<<block::binary, bytes::binary>> | acc]))
        end

      <<?z, rest::binary>> when digits == 0 ->
        C.bound(:stream_bytes, size + 4)
        C.tick(:decoded_bytes, 4)
        a85(rest, 0, 0, acc, <<block::binary, 0::32>>, size + 4, work + 1)

      <<c, rest::binary>> when c in 33..117 ->
        v = v * 85 + c - 33

        if digits == 4 do
          if v > 0xFFFFFFFF, do: C.fail(:invalid_ascii85)
          C.bound(:stream_bytes, size + 4)
          C.tick(:decoded_bytes, 4)
          a85(rest, 0, 0, acc, <<block::binary, v::32>>, size + 4, work + 1)
        else
          a85(rest, v, digits + 1, acc, block, size, work + 1)
        end

      _ ->
        C.fail(:invalid_ascii85)
    end
  end

  defp predictor(data, params) when is_map(params) do
    case Map.get(params, "Predictor", 1) do
      1 ->
        data

      n when n in 10..15 ->
        colors = Map.get(params, "Colors", 1)
        bits = Map.get(params, "BitsPerComponent", 8)
        cols = Map.get(params, "Columns", 1)

        if not (is_integer(colors) and colors in 1..32 and bits in [1, 2, 4, 8, 16] and
                  is_integer(cols) and cols > 0),
           do: C.fail(:invalid_predictor)

        row = div(colors * bits * cols + 7, 8)
        bpp = div(colors * bits + 7, 8)
        C.bound(:predictor_row, row)
        C.tick(:decoded_bytes, byte_size(data))
        png(data, :binary.copy(<<0>>, row), row, bpp, [])

      _ ->
        C.fail(:unsupported_predictor)
    end
  end

  defp predictor(_, _), do: C.fail(:invalid_predictor)
  defp png(<<>>, _, _, _, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp png(data, prev, row, bpp, acc) do
    C.check()

    case data do
      <<filter, raw::binary-size(^row), rest::binary>> when filter in 0..4 ->
        decoded = unfilter(raw, prev, filter, bpp, :queue.new(), 0, [])
        png(rest, decoded, row, bpp, [decoded | acc])

      _ ->
        C.fail(:invalid_predictor)
    end
  end

  defp unfilter(<<>>, _, _, _, _, _, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  defp unfilter(<<v, rest::binary>>, prev, filter, bpp, queue, i, acc) do
    {left, queue} =
      if i < bpp,
        do: {0, queue},
        else:
          (
            {{:value, x}, q} = :queue.out(queue)
            {x, q}
          )

    up = :binary.at(prev, i)
    ul = if i < bpp, do: 0, else: :binary.at(prev, i - bpp)

    predictor =
      case filter do
        0 -> 0
        1 -> left
        2 -> up
        3 -> div(left + up, 2)
        4 -> paeth(left, up, ul)
      end

    byte = band(v + predictor, 255)
    unfilter(rest, prev, filter, bpp, :queue.in(byte, queue), i + 1, [byte | acc])
  end

  defp paeth(a, b, c) do
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end
end
