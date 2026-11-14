defmodule ImageCheck.Png do
  @moduledoc false
  # PNG chunk and image data check modelled on libpng.
  #
  # Critical chunks must have valid CRCs and appear in a valid order; unknown
  # critical chunks are rejected and ancillary chunks are skipped without CRC
  # checks. The concatenated IDAT zlib stream is inflated incrementally with
  # bounded output per step, never buffered: it must end and produce exactly the
  # number of bytes required by the (optionally Adam7 interlaced) layout, with a
  # valid filter type at the start of every row. The zlib Adler-32 trailer is
  # ignored, as libpng-based decoders accept a wrong checksum.

  import Bitwise
  import ImageCheck, only: [fail: 1, check_pixels: 3]

  @signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @max_chunk_length 0x7FFF_FFFF

  # Adam7 passes: {x_start, y_start, x_step, y_step}.
  @adam7 [
    {0, 0, 8, 8},
    {4, 0, 8, 8},
    {0, 4, 4, 8},
    {2, 0, 4, 4},
    {0, 2, 2, 4},
    {1, 0, 2, 2},
    {0, 1, 1, 2}
  ]

  def header(<<@signature, rest::binary>>) do
    {ihdr, _rest} = read_ihdr(rest)
    {ihdr.width, ihdr.height}
  end

  def validate(<<@signature, rest::binary>>, max_pixels) do
    {ihdr, rest} = read_ihdr(rest)
    check_pixels(ihdr.width, ihdr.height, max_pixels)
    z = :zlib.open()

    try do
      state = %{
        ihdr: ihdr,
        z: z,
        zlib: {:header, <<>>},
        rows: rows(ihdr),
        palette?: false,
        idat: :none
      }

      chunks(rest, state)
      {ihdr.width, ihdr.height}
    after
      :zlib.close(z)
    end
  end

  defp read_ihdr(<<13::32, "IHDR", data::binary-size(13), crc::32, rest::binary>>) do
    check_crc("IHDR", data, crc)

    <<width::32, height::32, depth, color, compression, filter, interlace>> = data

    cond do
      width == 0 or height == 0 -> fail(:zero_dimension)
      width > @max_chunk_length or height > @max_chunk_length -> fail(:dimension_too_large)
      not valid_depth?(color, depth) -> fail(:invalid_bit_depth)
      compression != 0 -> fail(:invalid_compression_method)
      filter != 0 -> fail(:invalid_filter_method)
      interlace not in [0, 1] -> fail(:invalid_interlace_method)
      true -> :ok
    end

    ihdr = %{
      width: width,
      height: height,
      color: color,
      bits_per_pixel: channels(color) * depth,
      interlace: interlace
    }

    {ihdr, rest}
  end

  defp read_ihdr(<<_length::32, "IHDR", _rest::binary>>), do: fail(:invalid_ihdr)
  defp read_ihdr(<<_length::32, _type::binary-size(4), _rest::binary>>), do: fail(:missing_ihdr)
  defp read_ihdr(_data), do: fail(:truncated)

  defp valid_depth?(0, depth), do: depth in [1, 2, 4, 8, 16]
  defp valid_depth?(3, depth), do: depth in [1, 2, 4, 8]
  defp valid_depth?(color, depth) when color in [2, 4, 6], do: depth in [8, 16]
  defp valid_depth?(_color, _depth), do: false

  defp channels(0), do: 1
  defp channels(2), do: 3
  defp channels(3), do: 1
  defp channels(4), do: 2
  defp channels(6), do: 4

  defp chunks(<<length::32, type::binary-size(4), rest::binary>>, state)
       when length <= @max_chunk_length and byte_size(rest) >= length + 4 do
    <<data::binary-size(^length), crc::32, rest::binary>> = rest
    if not chunk_type?(type), do: fail(:invalid_chunk_type)
    critical? = (:binary.first(type) &&& 0x20) == 0
    if critical?, do: check_crc(type, data, crc)

    case type do
      "IDAT" ->
        chunks(rest, idat(data, state))

      "IEND" ->
        iend(data, state)

      "PLTE" ->
        chunks(rest, plte(data, state))

      "IHDR" ->
        fail(:duplicate_ihdr)

      _type when critical? ->
        fail(:unknown_critical_chunk)

      _ancillary ->
        chunks(rest, close_idat(state))
    end
  end

  defp chunks(<<length::32, _rest::binary>>, _state) when length > @max_chunk_length,
    do: fail(:invalid_chunk_length)

  defp chunks(<<>>, _state), do: fail(:missing_iend)
  defp chunks(_data, _state), do: fail(:truncated)

  defp chunk_type?(type),
    do: for(<<byte <- type>>, reduce: true, do: (acc -> acc and letter?(byte)))

  defp letter?(byte), do: byte in ?A..?Z or byte in ?a..?z

  defp check_crc(type, data, crc) do
    if :erlang.crc32(:erlang.crc32(type), data) != crc, do: fail(:bad_crc)
  end

  defp plte(_data, %{idat: idat}) when idat != :none, do: fail(:plte_after_idat)
  defp plte(_data, %{palette?: true}), do: fail(:duplicate_plte)

  defp plte(data, state) do
    entries = div(byte_size(data), 3)
    if rem(byte_size(data), 3) != 0 or entries == 0 or entries > 256, do: fail(:invalid_plte)
    %{state | palette?: true}
  end

  defp idat(_data, %{idat: :closed}), do: fail(:non_consecutive_idat)

  defp idat(_data, %{ihdr: %{color: 3}, palette?: false}), do: fail(:missing_plte)

  defp idat(data, state), do: inflate_data(data, %{state | idat: :open})

  defp close_idat(%{idat: :open} = state), do: %{state | idat: :closed}
  defp close_idat(state), do: state

  defp iend(_data, %{idat: :none}), do: fail(:missing_idat)
  defp iend(data, _state) when byte_size(data) != 0, do: fail(:invalid_iend)
  defp iend(_data, %{zlib: {:header, _bytes}}), do: fail(:truncated_zlib_stream)

  defp iend(_data, state) do
    if state.rows != :done, do: fail(:not_enough_image_data)

    try do
      :zlib.inflateEnd(state.z)
    rescue
      _error -> fail(:truncated_zlib_stream)
    end

    :ok
  end

  # The zlib header may be split across IDAT chunks. It is checked here and the
  # deflate stream is inflated raw, so the Adler-32 trailer is not verified.
  defp inflate_data(data, %{zlib: {:header, prefix}} = state) do
    needed = 2 - byte_size(prefix)

    if byte_size(data) < needed do
      %{state | zlib: {:header, prefix <> data}}
    else
      <<head::binary-size(^needed), rest::binary>> = data
      <<cmf, flg>> = prefix <> head

      cond do
        (cmf &&& 0x0F) != 8 or cmf >>> 4 > 7 -> fail(:invalid_zlib_header)
        rem(cmf * 256 + flg, 31) != 0 -> fail(:invalid_zlib_header)
        (flg &&& 0x20) != 0 -> fail(:invalid_zlib_header)
        true -> :ok
      end

      :ok = :zlib.inflateInit(state.z, -15)
      inflate(rest, %{state | zlib: :inflating})
    end
  end

  defp inflate_data(data, state), do: inflate(data, state)

  defp inflate(input, state) do
    result =
      try do
        :zlib.safeInflate(state.z, input)
      rescue
        _error -> fail(:corrupt_image_data)
      end

    case result do
      {:continue, output} -> inflate([], %{state | rows: consume(output, state.rows)})
      {:finished, output} -> %{state | rows: consume(output, state.rows)}
      {:need_dictionary, _adler, _output} -> fail(:invalid_zlib_header)
    end
  end

  ## Row layout

  # Each row is `{rows_left, row_bytes, bytes_left_in_row}` plus the remaining
  # passes; `bytes_left_in_row == 0` means the next byte is a filter type.
  defp rows(%{interlace: 0} = ihdr) do
    advance([{ihdr.height, row_bytes(ihdr.width, ihdr.bits_per_pixel)}])
  end

  defp rows(%{interlace: 1} = ihdr) do
    @adam7
    |> Enum.map(fn {x0, y0, dx, dy} ->
      width = pass_size(ihdr.width, x0, dx)
      height = pass_size(ihdr.height, y0, dy)
      if width == 0, do: {0, 0}, else: {height, row_bytes(width, ihdr.bits_per_pixel)}
    end)
    |> advance()
  end

  defp pass_size(size, start, _step) when size <= start, do: 0
  defp pass_size(size, start, step), do: div(size - start + step - 1, step)

  defp row_bytes(width, bits_per_pixel), do: div(width * bits_per_pixel + 7, 8)

  defp advance([]), do: :done
  defp advance([{0, _row_bytes} | passes]), do: advance(passes)
  defp advance([{rows, row_bytes} | passes]), do: {rows, row_bytes, 0, passes}

  defp consume(output, rows) when is_list(output),
    do: Enum.reduce(output, rows, fn part, rows -> consume(part, rows) end)

  defp consume(<<>>, rows), do: rows
  defp consume(_data, :done), do: fail(:too_much_image_data)

  defp consume(<<filter, rest::binary>>, {rows, row_bytes, 0, passes}) do
    if filter > 4, do: fail(:invalid_filter_type)
    consume(rest, {rows, row_bytes, row_bytes, passes})
  end

  defp consume(data, {rows, row_bytes, left, passes}) do
    taken = min(byte_size(data), left)
    <<_row::binary-size(^taken), rest::binary>> = data

    next =
      cond do
        taken < left -> {rows, row_bytes, left - taken, passes}
        rows > 1 -> {rows - 1, row_bytes, 0, passes}
        true -> advance(passes)
      end

    consume(rest, next)
  end
end
