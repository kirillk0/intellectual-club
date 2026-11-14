defmodule ImageCheck.Gif do
  @moduledoc false
  # GIF block structure check. Walks extensions, image descriptors, color
  # tables and data sub-blocks up to the trailer without decoding LZW data.
  # Every frame needs a nonzero size, an LZW minimum code size of 2..8 and at
  # least one data byte; a missing trailer (truncation) is an error.
  #
  # Frames may extend past the logical screen. Decoders such as Pillow then
  # grow the image, so the reported size is the union of the screen and every
  # frame rectangle, and the pixel limit applies to it as soon as each image
  # descriptor is read; as every frame lies within the union, this also bounds
  # the area of each frame. `header/1` reads the logical screen only.

  import Bitwise
  import ImageCheck, only: [fail: 1, check_pixels: 3]

  def header(
        <<"GIF", _version::binary-size(3), width::16-little, height::16-little, _rest::binary>>
      ) do
    check_dimensions(width, height)
    {width, height}
  end

  def header(_data), do: fail(:truncated)

  def validate(
        <<"GIF", _version::binary-size(3), width::16-little, height::16-little, flags,
          _background, _aspect, rest::binary>>,
        max_pixels
      ) do
    check_dimensions(width, height)
    check_pixels(width, height, max_pixels)
    rest = skip_color_table(rest, flags)
    blocks(rest, %{width: width, height: height, frames: 0, max_pixels: max_pixels})
  end

  def validate(_data, _max_pixels), do: fail(:truncated)

  defp check_dimensions(width, height) do
    if width == 0 or height == 0, do: fail(:zero_dimension)
  end

  defp skip_color_table(data, flags) when (flags &&& 0x80) == 0, do: data

  defp skip_color_table(data, flags) do
    size = 3 * (1 <<< ((flags &&& 0x07) + 1))
    if byte_size(data) < size, do: fail(:truncated)
    <<_table::binary-size(^size), rest::binary>> = data
    rest
  end

  defp blocks(<<0x3B, _rest::binary>>, %{frames: 0}), do: fail(:no_frames)
  defp blocks(<<0x3B, _rest::binary>>, state), do: {state.width, state.height}

  # Pillow reads the delay from bytes 1..2 of the first graphic control
  # sub-block, and the transparent index from byte 3 when flag bit 0 is set,
  # without a length check: shorter sub-blocks make it fail to open the file.
  # An empty first sub-block is skipped.
  defp blocks(<<0x21, 0xF9, size, flags, _rest::binary>>, _state)
       when size in [1, 2] or (size == 3 and (flags &&& 0x01) != 0),
       do: fail(:invalid_graphic_control)

  defp blocks(<<0x21, _label, rest::binary>>, state) do
    {_bytes, rest} = sub_blocks(rest, 0)
    blocks(rest, state)
  end

  defp blocks(
         <<0x2C, left::16-little, top::16-little, width::16-little, height::16-little, flags,
           rest::binary>>,
         state
       ) do
    if width == 0 or height == 0, do: fail(:zero_frame_dimension)

    state = %{
      state
      | width: max(state.width, left + width),
        height: max(state.height, top + height)
    }

    check_pixels(state.width, state.height, state.max_pixels)
    rest = skip_color_table(rest, flags)

    case rest do
      <<code_size, rest::binary>> when code_size in 2..8 ->
        {bytes, rest} = sub_blocks(rest, 0)
        if bytes == 0, do: fail(:empty_frame)
        blocks(rest, %{state | frames: state.frames + 1})

      <<_code_size, _rest::binary>> ->
        fail(:invalid_lzw_code_size)

      <<>> ->
        fail(:truncated)
    end
  end

  defp blocks(<<0x21>>, _state), do: fail(:truncated)
  defp blocks(<<0x2C, _rest::binary>>, _state), do: fail(:truncated)
  defp blocks(<<>>, _state), do: fail(:truncated)
  defp blocks(_data, _state), do: fail(:invalid_block)

  defp sub_blocks(<<0, rest::binary>>, bytes), do: {bytes, rest}

  defp sub_blocks(<<size, data::binary>>, bytes) when byte_size(data) >= size do
    <<_block::binary-size(^size), rest::binary>> = data
    sub_blocks(rest, bytes + size)
  end

  defp sub_blocks(_data, _bytes), do: fail(:truncated)
end
