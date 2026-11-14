defmodule ImageCheck.Jpeg do
  @moduledoc false
  # Marker-level JPEG check modelled on libjpeg(-turbo) header parsing.
  #
  # Requires exactly one SOF0/SOF1/SOF2 frame with 8-bit precision and at least
  # one complete SOS header whose components and tables are defined. Entropy
  # coded data is skipped, never decoded. Truncation after the first complete
  # scan header and a missing EOI are accepted, as common decoders render such
  # files. Sequential frames stop being checked once every frame component has
  # been scanned; progressive frames are walked scan by scan until EOI or EOF.

  import Bitwise
  import ImageCheck, only: [fail: 1, check_pixels: 3]

  # libjpeg JPEG_MAX_DIMENSION and D_MAX_BLOCKS_IN_MCU.
  @max_dimension 65_500
  @max_blocks_in_mcu 10

  @sof_supported [0xC0, 0xC1, 0xC2]
  @sof_unsupported [0xC3, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF, 0xDE, 0xDF]

  def header(<<0xFF, 0xD8, rest::binary>>), do: header_segments(rest)
  def header(_data), do: fail(:missing_soi)

  def validate(<<0xFF, 0xD8, rest::binary>>, max_pixels) do
    state = %{
      max_pixels: max_pixels,
      frame: nil,
      quant: 0,
      dc: 0,
      ac: 0,
      scans: 0,
      scanned: MapSet.new()
    }

    segments(rest, state)
  end

  def validate(_data, _max_pixels), do: fail(:missing_soi)

  ## Header-only walk

  defp header_segments(<<0xFF, rest::binary>>), do: header_marker(rest)
  defp header_segments(<<>>), do: fail(:missing_frame)
  defp header_segments(_data), do: fail(:missing_marker)

  defp header_marker(<<0xFF, rest::binary>>), do: header_marker(rest)

  defp header_marker(<<marker, rest::binary>>) when marker in [0x01] or marker in 0xD0..0xD7,
    do: header_segments(rest)

  defp header_marker(<<marker, length::16, rest::binary>>)
       when marker not in [0x00, 0xD8, 0xD9, 0xDA] and length >= 2 and
              byte_size(rest) >= length - 2 do
    <<body::binary-size(^length - 2), rest::binary>> = rest

    cond do
      marker in @sof_supported ->
        frame = parse_frame(body)
        {frame.width, frame.height}

      marker in @sof_unsupported ->
        fail(:unsupported_process)

      true ->
        header_segments(rest)
    end
  end

  defp header_marker(<<marker, _rest::binary>>) when marker == 0xDA, do: fail(:scan_before_frame)
  defp header_marker(<<0xD9, _rest::binary>>), do: fail(:missing_frame)

  defp header_marker(<<marker, _rest::binary>>) when marker in [0x00, 0xD8],
    do: fail(:invalid_marker)

  defp header_marker(_data), do: fail(:segment_out_of_bounds)

  ## Full walk

  defp segments(<<0xFF, rest::binary>>, state), do: marker(rest, state)
  defp segments(<<>>, state), do: finish(state)
  # Like libjpeg, skip extraneous bytes before the next marker between scans.
  defp segments(data, %{scans: scans} = state) when scans > 0, do: entropy(data, state)
  defp segments(_data, _state), do: fail(:missing_marker)

  # Any number of 0xFF fill bytes may precede a marker.
  defp marker(<<0xFF, rest::binary>>, state), do: marker(rest, state)
  defp marker(<<0xD9, _rest::binary>>, state), do: finish(state)
  defp marker(<<0xD8, _rest::binary>>, _state), do: fail(:unexpected_soi)
  defp marker(<<0x00, _rest::binary>>, _state), do: fail(:invalid_marker)

  defp marker(<<marker, rest::binary>>, state) when marker == 0x01 or marker in 0xD0..0xD7,
    do: segments(rest, state)

  defp marker(<<marker, length::16, rest::binary>>, state)
       when length >= 2 and byte_size(rest) >= length - 2 do
    <<body::binary-size(^length - 2), rest::binary>> = rest
    segment(marker, body, rest, state)
  end

  defp marker(<<_marker, length::16, _rest::binary>>, _state) when length < 2,
    do: fail(:invalid_segment_length)

  # The file ends inside a marker segment. After a complete scan header this is
  # an ordinary truncation; before it the headers themselves are incomplete.
  defp marker(_data, %{scans: scans} = state) when scans > 0, do: finish(state)
  defp marker(_data, _state), do: fail(:segment_out_of_bounds)

  defp segment(marker, body, rest, state) when marker in @sof_supported do
    if state.frame, do: fail(:multiple_frames)
    frame = parse_frame(body)
    check_pixels(frame.width, frame.height, state.max_pixels)
    segments(rest, %{state | frame: Map.put(frame, :progressive, marker == 0xC2)})
  end

  defp segment(marker, _body, _rest, _state) when marker in @sof_unsupported,
    do: fail(:unsupported_process)

  defp segment(0xC4, body, rest, state), do: segments(rest, parse_dht(body, state))
  defp segment(0xDB, body, rest, state), do: segments(rest, parse_dqt(body, state))

  defp segment(0xDD, body, rest, state) do
    if byte_size(body) != 2, do: fail(:invalid_dri)
    segments(rest, state)
  end

  defp segment(0xDA, body, rest, state) do
    state = parse_sos(body, state)

    if not state.frame.progressive and
         MapSet.size(state.scanned) == length(state.frame.components) do
      # Every component of a sequential frame has been scanned: the remaining
      # bytes do not affect how the image decodes.
      {state.frame.width, state.frame.height}
    else
      entropy(rest, state)
    end
  end

  # DAC only matters for arithmetic coding, which is rejected at SOF; DNL is
  # irrelevant because zero heights are rejected at SOF.
  defp segment(marker, _body, rest, state)
       when marker in [0xCC, 0xDC, 0xFE] or marker in 0xE0..0xEF,
       do: segments(rest, state)

  defp segment(_marker, _body, _rest, _state), do: fail(:unknown_marker)

  # Skips entropy-coded data up to the next marker. Stuffed 0xFF00 bytes,
  # restart markers and fill bytes belong to the scan.
  defp entropy(data, state) do
    case :binary.match(data, <<0xFF>>) do
      :nomatch ->
        finish(state)

      {position, 1} ->
        <<_skipped::binary-size(^position), 0xFF, rest::binary>> = data

        case rest do
          <<>> -> finish(state)
          <<byte, rest::binary>> when byte == 0x00 or byte in 0xD0..0xD7 -> entropy(rest, state)
          <<0xFF, _rest::binary>> -> entropy(rest, state)
          _marker -> marker(rest, state)
        end
    end
  end

  defp finish(%{frame: nil}), do: fail(:missing_frame)
  defp finish(%{scans: 0}), do: fail(:missing_scan)
  defp finish(%{frame: frame}), do: {frame.width, frame.height}

  ## Segment parsers

  defp parse_frame(<<precision, height::16, width::16, count, rest::binary>>) do
    cond do
      precision != 8 -> fail(:unsupported_precision)
      width == 0 or height == 0 -> fail(:zero_dimension)
      width > @max_dimension or height > @max_dimension -> fail(:dimension_too_large)
      count not in [1, 3, 4] -> fail(:unsupported_component_count)
      byte_size(rest) != count * 3 -> fail(:invalid_sof_length)
      true -> :ok
    end

    components =
      for <<id, h::4, v::4, table <- rest>> do
        if h not in 1..4 or v not in 1..4, do: fail(:invalid_sampling_factor)
        if table > 3, do: fail(:invalid_quantization_table_index)
        %{id: id, h: h, v: v, quant: table}
      end

    if length(Enum.uniq_by(components, & &1.id)) != count, do: fail(:duplicate_component)

    # libjpeg upsampling supports only integral sampling ratios.
    max_h = components |> Enum.map(& &1.h) |> Enum.max()
    max_v = components |> Enum.map(& &1.v) |> Enum.max()

    if Enum.any?(components, &(rem(max_h, &1.h) != 0 or rem(max_v, &1.v) != 0)),
      do: fail(:unsupported_sampling)

    %{width: width, height: height, components: components}
  end

  defp parse_frame(_body), do: fail(:invalid_sof_length)

  defp parse_dqt(<<>>, _state), do: fail(:invalid_dqt)
  defp parse_dqt(body, state), do: parse_dqt_tables(body, state)

  defp parse_dqt_tables(<<>>, state), do: state

  defp parse_dqt_tables(<<precision::4, index::4, rest::binary>>, state) do
    if precision > 1, do: fail(:invalid_dqt)
    if index > 3, do: fail(:invalid_quantization_table_index)
    size = 64 * (precision + 1)
    if byte_size(rest) < size, do: fail(:invalid_dqt)
    <<_values::binary-size(^size), rest::binary>> = rest
    parse_dqt_tables(rest, %{state | quant: state.quant ||| 1 <<< index})
  end

  defp parse_dht(<<>>, _state), do: fail(:invalid_dht)
  defp parse_dht(body, state), do: parse_dht_tables(body, state)

  defp parse_dht_tables(<<>>, state), do: state

  defp parse_dht_tables(<<class::4, index::4, counts::binary-size(16), rest::binary>>, state) do
    if class > 1, do: fail(:invalid_huffman_table_class)
    if index > 3, do: fail(:invalid_huffman_table_index)
    counts = :binary.bin_to_list(counts)
    total = Enum.sum(counts)
    if total == 0 or total > 256 or byte_size(rest) < total, do: fail(:invalid_huffman_table)
    check_code_space(counts)
    <<symbols::binary-size(^total), rest::binary>> = rest

    # DC difference categories above 15 are invalid for any precision.
    if class == 0 and Enum.any?(:binary.bin_to_list(symbols), &(&1 > 15)),
      do: fail(:invalid_huffman_table)

    state =
      if class == 0,
        do: %{state | dc: state.dc ||| 1 <<< index},
        else: %{state | ac: state.ac ||| 1 <<< index}

    parse_dht_tables(rest, state)
  end

  defp parse_dht_tables(_body, _state), do: fail(:invalid_dht)

  # Canonical Huffman codes must fit the code space at every length, and the
  # all-ones code is reserved (the libjpeg "Bogus Huffman table" check).
  defp check_code_space(counts) do
    Enum.reduce(Enum.with_index(counts, 1), 0, fn {count, length}, code ->
      code = code + count
      if code >= 1 <<< length, do: fail(:invalid_huffman_table)
      code <<< 1
    end)
  end

  defp parse_sos(_body, %{frame: nil}), do: fail(:scan_before_frame)

  defp parse_sos(<<count, rest::binary>>, state)
       when count in 1..4 and byte_size(rest) == count * 2 + 3 do
    <<selectors::binary-size(^count * 2), start, finish, high::4, low::4>> = rest
    frame = state.frame

    components =
      for <<id, dc::4, ac::4 <- selectors>> do
        component = Enum.find(frame.components, &(&1.id == id)) || fail(:unknown_scan_component)
        if dc > 3 or ac > 3, do: fail(:invalid_huffman_table_index)
        Map.merge(component, %{dc: dc, ac: ac})
      end

    if length(Enum.uniq_by(components, & &1.id)) != count, do: fail(:duplicate_scan_component)

    if count > 1 and Enum.sum(Enum.map(components, &(&1.h * &1.v))) > @max_blocks_in_mcu,
      do: fail(:mcu_too_large)

    {needs_dc?, needs_ac?} =
      if frame.progressive do
        check_progression(start, finish, high, low, count)
        dc_band? = start == 0
        {dc_band? and high == 0, not dc_band?}
      else
        if start > finish or finish > 63, do: fail(:invalid_spectral_selection)
        {true, true}
      end

    for component <- components do
      if not defined?(state.quant, component.quant), do: fail(:undefined_quantization_table)
      if needs_dc? and not defined?(state.dc, component.dc), do: fail(:undefined_huffman_table)
      if needs_ac? and not defined?(state.ac, component.ac), do: fail(:undefined_huffman_table)
    end

    %{
      state
      | scans: state.scans + 1,
        scanned: Enum.reduce(components, state.scanned, &MapSet.put(&2, &1.id))
    }
  end

  defp parse_sos(_body, _state), do: fail(:invalid_sos)

  defp check_progression(start, finish, high, low, count) do
    cond do
      start == 0 and finish != 0 -> fail(:invalid_progression)
      start != 0 and (start > finish or finish > 63 or count != 1) -> fail(:invalid_progression)
      high != 0 and low != high - 1 -> fail(:invalid_progression)
      low > 13 -> fail(:invalid_progression)
      true -> :ok
    end
  end

  defp defined?(mask, index), do: (mask &&& 1 <<< index) != 0
end
