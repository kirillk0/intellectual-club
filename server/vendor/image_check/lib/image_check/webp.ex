defmodule ImageCheck.Webp do
  @moduledoc false
  # RIFF/WebP container check modelled on libwebp. WebPAnimDecoder, which
  # Pillow uses for every WebP file, runs both WebPGetFeatures
  # (src/dec/webp_dec.c) and the demuxer (src/demux/demux.c) before decoding
  # each frame with WebPDecode, so the rules are those of all three.
  #
  # The RIFF size must fit the payload (trailing bytes are ignored) and every
  # chunk must lie within it. A frame is read like the demuxer's StoreFrame:
  # at most one ALPH and one VP8 or VP8L chunk, adjacent, where ALPH cannot go
  # with VP8L. Simple files start with a frame. Extended files start with a
  # 10-byte VP8X chunk without reserved flags and hold either one still frame
  # matching the canvas, or ANIM followed by ANMF frames that fit the canvas;
  # other ALPH, VP8, VP8L or VP8X chunks are errors. ALPH is checked where
  # libwebp decodes it: in ANMF frames, and in still frames when the VP8X alpha
  # flag is set (the demuxer drops it otherwise). Bitstream headers are checked
  # up to where entropy decoding starts; no image data is decoded.

  import Bitwise
  import ImageCheck, only: [fail: 1, check_pixels: 3]

  @max_canvas_area 0xFFFF_FFFF
  # VP8X flag bits outside libwebp's ALL_VALID_FLAGS (0x3E).
  @reserved_flags 0xC1
  @animation_flag 0x02
  @alpha_flag 0x10
  @frame_chunks ["ALPH", "VP8 ", "VP8L"]
  # VP8 frame tag (3 bytes), start code and dimensions (7 bytes).
  @vp8_header_size 10
  @vp8l_header_size 5
  # The shortest lossless image stream has no transforms, color cache or meta
  # prefix codes and five single-symbol prefix codes of four bits each. Its
  # last required set bit is bit 19, so it takes at least three bytes.
  @min_lossless_stream 3

  def header(<<"RIFF", _size::32-little, "WEBP", rest::binary>>) do
    case rest do
      <<"VP8 ", size::32-little, data::binary>> ->
        vp8(binary_part(data, 0, min(size, byte_size(data))))

      <<"VP8L", size::32-little, data::binary>> ->
        vp8l(binary_part(data, 0, min(size, byte_size(data))))

      <<"VP8X", _size::32-little, data::binary>> ->
        vp8x_canvas(data)

      <<_fourcc::binary-size(4), _rest::binary>> ->
        fail(:invalid_first_chunk)

      _data ->
        fail(:truncated)
    end
  end

  def validate(<<"RIFF", riff_size::32-little, "WEBP", _rest::binary>> = data, max_pixels) do
    if riff_size < 12, do: fail(:invalid_riff_size)
    if byte_size(data) < riff_size + 8, do: fail(:truncated)
    chunks = binary_part(data, 12, riff_size - 4)

    case next_chunk(chunks) do
      {fourcc, _payload, _pad, _rest} when fourcc in ["VP8 ", "VP8L"] ->
        simple(chunks, max_pixels)

      {"VP8X", header, _pad, rest} ->
        extended(header, rest, max_pixels)

      _other ->
        fail(:invalid_first_chunk)
    end
  end

  # Chunks are walked one at a time, never collected: a payload of many tiny
  # chunks must not cost more memory than the payload itself. Payloads are
  # padded to even sizes; a missing pad after the final chunk is tolerated as
  # libwebp does. `pad` is 1 when a pad byte follows the payload.
  defp next_chunk(<<>>), do: :done

  defp next_chunk(<<fourcc::binary-size(4), size::32-little, rest::binary>>)
       when byte_size(rest) >= size do
    <<payload::binary-size(^size), rest::binary>> = rest

    case {rem(size, 2), rest} do
      {1, <<_pad, rest::binary>>} -> {fourcc, payload, 1, rest}
      _other -> {fourcc, payload, 0, rest}
    end
  end

  defp next_chunk(_data), do: fail(:chunk_out_of_bounds)

  defp reduce_chunks(data, acc, fun) do
    case next_chunk(data) do
      :done -> acc
      {fourcc, payload, _pad, rest} -> reduce_chunks(rest, fun.(fourcc, payload, acc), fun)
    end
  end

  # The demuxer reads the frame at the start of a simple file and ignores the
  # remaining chunks; without VP8X an ALPH chunk is not used.
  defp simple(chunks, max_pixels) do
    {%{image: {width, height} = size}, rest} = frame(chunks)
    reduce_chunks(rest, :ok, fn _fourcc, _payload, acc -> acc end)
    check_pixels(width, height, max_pixels)
    size
  end

  defp extended(
         <<flags, _reserved::24, width::24-little, height::24-little>>,
         chunks,
         max_pixels
       ) do
    if (flags &&& @reserved_flags) != 0, do: fail(:invalid_vp8x_flags)
    {width, height} = canvas = canvas(width + 1, height + 1)
    check_pixels(width, height, max_pixels)

    if (flags &&& @animation_flag) != 0,
      do: animation(chunks, canvas),
      else: still(chunks, flags, canvas)

    canvas
  end

  # WebPGetFeatures requires a VP8X payload of exactly 10 bytes.
  defp extended(_header, _chunks, _max_pixels), do: fail(:invalid_vp8x)

  defp vp8x_canvas(<<_flags, _reserved::24, width::24-little, height::24-little, _rest::binary>>),
    do: canvas(width + 1, height + 1)

  defp vp8x_canvas(_data), do: fail(:invalid_vp8x)

  defp canvas(width, height) do
    if width * height > @max_canvas_area, do: fail(:dimension_too_large)
    {width, height}
  end

  ## Frames

  # One frame as the demuxer's StoreFrame reads it: an optional ALPH and a VP8
  # or VP8L chunk in either order; the first other chunk ends the frame.
  # Returns the frame and the chunks after it.
  defp frame(chunks), do: frame(chunks, %{image: nil, alpha: nil, alpha_first?: false})

  defp frame(chunks, frame) do
    case {next_chunk(chunks), frame} do
      {{"ALPH", alpha, _pad, rest}, %{alpha: nil, image: image}} ->
        frame(rest, %{frame | alpha: alpha, alpha_first?: image == nil})

      {{"VP8L", _bitstream, _pad, _rest}, %{alpha: alpha}} when alpha != nil ->
        fail(:alpha_with_lossless)

      {{"VP8 ", bitstream, pad, rest}, %{image: nil}} ->
        frame(rest, %{frame | image: vp8_frame(bitstream, pad)})

      {{"VP8L", bitstream, pad, rest}, %{image: nil}} ->
        frame(rest, %{frame | image: vp8l_frame(bitstream, pad)})

      _other ->
        {frame, chunks}
    end
  end

  # Still extended image: the first ALPH, VP8 or VP8L chunk starts the frame.
  defp still(chunks, flags, canvas) do
    case next_chunk(chunks) do
      :done ->
        fail(:missing_bitstream)

      {fourcc, _payload, _pad, rest} when fourcc not in @frame_chunks ->
        still_chunk(fourcc)
        still(rest, flags, canvas)

      _frame_chunk ->
        {frame, rest} = frame(chunks)
        if (frame.image || fail(:missing_bitstream)) != canvas, do: fail(:canvas_size_mismatch)
        if (flags &&& @alpha_flag) != 0, do: check_alpha(frame)
        reduce_chunks(rest, :ok, fn fourcc, _payload, :ok -> still_chunk(fourcc) end)
    end
  end

  defp still_chunk(fourcc) when fourcc in @frame_chunks, do: fail(:multiple_bitstreams)
  defp still_chunk("VP8X"), do: fail(:duplicate_vp8x)
  defp still_chunk(fourcc) when fourcc in ["ANIM", "ANMF"], do: fail(:unexpected_animation)
  defp still_chunk(_fourcc), do: :ok

  defp animation(chunks, canvas) do
    result =
      reduce_chunks(chunks, %{anim?: false, frames: 0}, fn fourcc, payload, acc ->
        animation_chunk(fourcc, payload, acc, canvas)
      end)

    if not result.anim?, do: fail(:missing_anim)
    if result.frames == 0, do: fail(:no_frames)
  end

  defp animation_chunk("ANIM", payload, acc, _canvas) do
    if byte_size(payload) < 6, do: fail(:invalid_anim)
    %{acc | anim?: true}
  end

  defp animation_chunk("ANMF", _payload, %{anim?: false}, _canvas), do: fail(:anmf_before_anim)

  defp animation_chunk(
         "ANMF",
         <<x::24-little, y::24-little, width::24-little, height::24-little, _duration::24, _flags,
           data::binary>>,
         acc,
         {canvas_width, canvas_height}
       ) do
    width = width + 1
    height = height + 1

    if x * 2 + width > canvas_width or y * 2 + height > canvas_height,
      do: fail(:frame_outside_canvas)

    {frame, rest} = frame(data)

    if (frame.image || fail(:missing_bitstream)) != {width, height},
      do: fail(:frame_size_mismatch)

    check_alpha(frame)
    frame_rest(rest)
    %{acc | frames: acc.frames + 1}
  end

  defp animation_chunk("ANMF", _payload, _acc, _canvas), do: fail(:invalid_anmf)
  defp animation_chunk("VP8X", _payload, _acc, _canvas), do: fail(:duplicate_vp8x)

  defp animation_chunk(fourcc, _payload, _acc, _canvas) when fourcc in @frame_chunks,
    do: fail(:bitstream_outside_frame)

  defp animation_chunk(_fourcc, _payload, acc, _canvas), do: acc

  # The demuxer reads the chunks that follow the frame inside an ANMF payload
  # as top-level chunks. A nested ANMF is rejected instead of being walked
  # recursively.
  defp frame_rest(rest) do
    reduce_chunks(rest, :ok, fn
      "ANMF", _payload, :ok ->
        fail(:invalid_anmf)

      fourcc, payload, :ok ->
        animation_chunk(fourcc, payload, %{anim?: true, frames: 0}, nil)
        :ok
    end)
  end

  ## Alpha

  # The alpha must precede its bitstream; libwebp ALPHInit then needs a header
  # byte with zero reserved bits, compression 0 (raw) or 1 (lossless) and
  # pre-processing 0 or 1 (all four filters are valid), followed by at least
  # width * height raw bytes or a lossless stream.
  defp check_alpha(%{alpha: nil}), do: :ok
  defp check_alpha(%{alpha_first?: false}), do: fail(:alpha_after_bitstream)

  defp check_alpha(%{alpha: alpha, image: {width, height}}) do
    case alpha do
      <<reserved::2, preprocessing::2, _filtering::2, compression::2, data::binary>> ->
        cond do
          reserved != 0 or preprocessing > 1 or compression > 1 -> fail(:invalid_alpha_header)
          compression == 0 and byte_size(data) < width * height -> fail(:truncated_alpha)
          compression == 1 and byte_size(data) < @min_lossless_stream -> fail(:truncated_alpha)
          true -> :ok
        end

      <<>> ->
        fail(:truncated_alpha)
    end
  end

  ## Bitstream headers

  # VP8GetInfo, as used by WebPGetFeatures and the demuxer.
  defp vp8(<<b0, b1, b2, rest::binary>> = data) when byte_size(rest) >= 7 do
    bits = b0 ||| b1 <<< 8 ||| b2 <<< 16

    cond do
      (bits &&& 1) != 0 -> fail(:not_key_frame)
      (bits >>> 1 &&& 7) > 3 -> fail(:invalid_vp8_profile)
      (bits >>> 4 &&& 1) == 0 -> fail(:invisible_frame)
      bits >>> 5 >= byte_size(data) -> fail(:invalid_partition_size)
      true -> :ok
    end

    case rest do
      <<0x9D, 0x01, 0x2A, width::16-little, height::16-little, _rest::binary>> ->
        dimensions(width &&& 0x3FFF, height &&& 0x3FFF)

      _other ->
        fail(:invalid_vp8_signature)
    end
  end

  defp vp8(_data), do: fail(:truncated_bitstream)

  # The frame data WebPDecode reads includes the pad byte of an odd-sized
  # chunk. VP8GetHeaders reads partition 0 right after the 10-byte frame
  # header; an empty one ends before its first field. ParsePartitions then
  # needs at least one byte for the token partitions.
  defp vp8_frame(bitstream, pad) do
    size = vp8(bitstream)
    <<b0, b1, b2, _rest::binary>> = bitstream
    partition = (b0 ||| b1 <<< 8 ||| b2 <<< 16) >>> 5

    if partition == 0 or @vp8_header_size + partition >= byte_size(bitstream) + pad,
      do: fail(:invalid_partition_size)

    size
  end

  # VP8LGetInfo, as used by WebPGetFeatures and the demuxer.
  defp vp8l(<<0x2F, bits::32-little, _rest::binary>>) do
    if bits >>> 29 != 0, do: fail(:invalid_vp8l_version)
    {(bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1}
  end

  defp vp8l(<<_signature, _bits::32, _rest::binary>>), do: fail(:invalid_vp8l_signature)
  defp vp8l(_data), do: fail(:truncated_bitstream)

  defp vp8l_frame(bitstream, pad) do
    size = vp8l(bitstream)

    if byte_size(bitstream) + pad < @vp8l_header_size + @min_lossless_stream,
      do: fail(:truncated_bitstream)

    size
  end

  defp dimensions(0, _height), do: fail(:zero_dimension)
  defp dimensions(_width, 0), do: fail(:zero_dimension)
  defp dimensions(width, height), do: {width, height}
end
