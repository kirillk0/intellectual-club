defmodule ImageCheckTest do
  use ExUnit.Case, async: true

  @fixtures Path.expand("fixtures", __DIR__)

  @valid %{
    "baseline.jpg" => {:jpeg, 17, 9},
    "baseline_444.jpg" => {:jpeg, 8, 8},
    "photo.jpg" => {:jpeg, 96, 64},
    "photo_progressive.jpg" => {:jpeg, 96, 64},
    "progressive.jpg" => {:jpeg, 32, 24},
    "cmyk.jpg" => {:jpeg, 16, 16},
    "grayscale.jpg" => {:jpeg, 12, 10},
    "restart.jpg" => {:jpeg, 40, 24},
    "rgb.png" => {:png, 7, 5},
    "gray16.png" => {:png, 5, 4},
    "rgba16_pypng.png" => {:png, 6, 5},
    "palette.png" => {:png, 9, 3},
    "gray1.png" => {:png, 13, 5},
    "adam7_rgb.png" => {:png, 11, 9},
    "adam7_gray2.png" => {:png, 5, 3},
    "adam7_1x1.png" => {:png, 1, 1},
    "adam7_rgba16.png" => {:png, 3, 17},
    "animated.png" => {:png, 6, 4},
    "static.gif" => {:gif, 9, 7},
    "animated.gif" => {:gif, 8, 6},
    "lossy.webp" => {:webp, 10, 6},
    "lossless.webp" => {:webp, 10, 6},
    "alpha.webp" => {:webp, 10, 6},
    "animated.webp" => {:webp, 12, 8},
    "icc.webp" => {:webp, 6, 4}
  }

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp accepted(payload) do
    assert {:ok, %{format: _, mime_type: _, width: _, height: _}} = ImageCheck.validate(payload)
  end

  defp rejected(payload, reason) do
    assert {:error, ^reason} = ImageCheck.validate(payload)
  end

  describe "valid images" do
    for {name, {format, width, height}} <- @valid do
      test "accepts #{name}" do
        payload = fixture(unquote(name))
        format = unquote(format)
        mime_type = "image/#{format}"

        expected = %{
          format: format,
          mime_type: mime_type,
          width: unquote(width),
          height: unquote(height)
        }

        assert ImageCheck.header(payload) == {:ok, expected}
        assert ImageCheck.validate(payload) == {:ok, expected}
      end
    end

    test "accepts minimal generated PNGs" do
      accepted(png(1, 1, 8, 6, :binary.copy(<<0, 1, 2, 3, 4>>, 1)))
      accepted(png(2, 1, 16, 2, <<1>> <> :binary.copy(<<0>>, 12)))
    end
  end

  describe "unsupported and unknown payloads" do
    test "recognizes formats that are not accepted" do
      assert ImageCheck.validate(fixture("image.bmp")) == {:error, {:unsupported_format, :bmp}}
      assert ImageCheck.validate(fixture("image.tiff")) == {:error, {:unsupported_format, :tiff}}
      assert ImageCheck.validate(fixture("image.avif")) == {:error, {:unsupported_format, :avif}}

      heic = <<0, 0, 0, 24, "ftypheic", 0, 0, 0, 0, "mif1heic">>
      assert ImageCheck.header(heic) == {:error, {:unsupported_format, :heic}}
    end

    test "rejects non-image payloads" do
      for payload <- ["", "not an image", "<html>404</html>", <<0xFF, 0xD8>>, <<0x89, "PNG">>] do
        assert {:error, :unknown_format} = ImageCheck.validate(payload)
      end
    end

    test "rejects invalid arguments without raising" do
      assert ImageCheck.validate(:not_binary) == {:error, :invalid_arguments}
      assert ImageCheck.validate(fixture("rgb.png"), max_pixels: 0) == {:error, :invalid_options}
      assert ImageCheck.header(nil) == {:error, :not_binary}
    end

    test "applies the pixel limit before reading image data" do
      for name <- ["photo.jpg", "rgb.png", "static.gif", "lossy.webp", "animated.webp"] do
        assert {:error, :too_many_pixels} = ImageCheck.validate(fixture(name), max_pixels: 20)
        assert {:ok, _info} = ImageCheck.validate(fixture(name), max_pixels: :infinity)
      end
    end
  end

  describe "JPEG damage accepted by providers" do
    test "truncation inside the scan data and a missing EOI" do
      payload = fixture("photo.jpg")

      for ratio <- [0.5, 0.9] do
        accepted(binary_part(payload, 0, trunc(byte_size(payload) * ratio)))
      end

      accepted(binary_part(payload, 0, byte_size(payload) - 2))
      progressive = fixture("photo_progressive.jpg")
      accepted(binary_part(progressive, 0, trunc(byte_size(progressive) * 0.6)))
    end

    test "garbage in the scan data and after EOI" do
      payload = fixture("photo.jpg")
      {scan_start, _} = scan_data_range(payload)
      garbage = :crypto.strong_rand_bytes(1_000)
      <<head::binary-size(^scan_start + 200), _::binary-size(1_000), tail::binary>> = payload
      accepted(head <> garbage <> tail)
      accepted(payload <> :crypto.strong_rand_bytes(500))
    end

    test "headers with a complete scan header but no scan data" do
      payload = fixture("photo.jpg")
      {scan_start, _} = scan_data_range(payload)
      headers = binary_part(payload, 0, scan_start)
      accepted(headers)
      accepted(headers <> <<0xFF, 0xD9>>)
    end
  end

  describe "JPEG damage rejected by providers" do
    test "a Huffman table that overflows its code space" do
      payload = fixture("photo.jpg")
      rejected(overflow_first_huffman_table(payload), {:jpeg, :invalid_huffman_table})
    end

    test "zero width or height" do
      payload = fixture("baseline.jpg")
      rejected(put_frame_size(payload, 0, 9), {:jpeg, :zero_dimension})
      rejected(put_frame_size(payload, 17, 0), {:jpeg, :zero_dimension})
    end

    test "a segment longer than the file" do
      <<soi::binary-size(2), 0xFF, 0xE0, _length::16, rest::binary>> = fixture("baseline.jpg")
      rejected(soi <> <<0xFF, 0xE0, 0xFFFF::16>> <> rest, {:jpeg, :segment_out_of_bounds})
    end

    test "truncation before the first complete scan header" do
      payload = fixture("photo.jpg")
      {scan_start, _} = scan_data_range(payload)
      rejected(binary_part(payload, 0, scan_start - 3), {:jpeg, :segment_out_of_bounds})
      rejected(binary_part(payload, 0, 200), {:jpeg, :segment_out_of_bounds})
    end

    test "a huge declared frame" do
      payload = put_frame_size(fixture("baseline.jpg"), 30_000, 30_000)
      rejected(payload, :too_many_pixels)
      assert {:ok, %{width: 30_000, height: 30_000}} = ImageCheck.header(payload)
    end
  end

  describe "JPEG structure" do
    test "rejects unsupported coding processes and precision" do
      payload = fixture("baseline.jpg")
      rejected(replace_marker(payload, 0xC0, 0xC3), {:jpeg, :unsupported_process})
      rejected(replace_marker(payload, 0xC0, 0xC9), {:jpeg, :unsupported_process})
      {offset, _length} = segment(payload, 0xC0)
      rejected(put_byte(payload, offset + 4, 12), {:jpeg, :unsupported_precision})
    end

    test "rejects scans that reference undefined components or tables" do
      payload = fixture("baseline.jpg")
      {offset, _length} = segment(payload, 0xDA)
      rejected(put_byte(payload, offset + 5, 9), {:jpeg, :unknown_scan_component})
      rejected(put_byte(payload, offset + 6, 0x33), {:jpeg, :undefined_huffman_table})
    end

    test "rejects scans before the frame, missing scans and repeated frames" do
      payload = fixture("baseline.jpg")
      {sof, sof_length} = segment(payload, 0xC0)
      sof_segment = binary_part(payload, sof, sof_length + 2)
      without_sof = remove(payload, sof, sof_length + 2)
      rejected(without_sof, {:jpeg, :scan_before_frame})

      {sos, _length} = segment(payload, 0xDA)
      rejected(binary_part(payload, 0, sos) <> <<0xFF, 0xD9>>, {:jpeg, :missing_scan})
      rejected(insert(payload, sof, sof_segment), {:jpeg, :multiple_frames})
    end

    test "rejects invalid progressive scan parameters" do
      payload = fixture("progressive.jpg")
      {offset, length} = segment(payload, 0xDA)
      # Spectral selection end of the first (DC) scan.
      rejected(put_byte(payload, offset + length - 1, 5), {:jpeg, :invalid_progression})
    end

    test "walks later progressive scans" do
      payload = fixture("photo_progressive.jpg")
      {offset, _length} = last_segment(payload, 0xDA)
      rejected(put_byte(payload, offset + 5, 9), {:jpeg, :unknown_scan_component})
    end

    test "skips extraneous bytes before markers only after the first scan" do
      payload = fixture("photo_progressive.jpg")
      {last_scan, _length} = last_segment(payload, 0xDA)
      accepted(insert(payload, last_scan, <<1, 2, 3>>))
      {first_scan, _length} = segment(payload, 0xDA)
      rejected(insert(payload, first_scan, <<1, 2, 3>>), {:jpeg, :missing_marker})
    end
  end

  describe "PNG damage rejected by providers" do
    test "truncation" do
      payload = fixture("adam7_rgb.png")

      for size <- [12, 33, 40, div(byte_size(payload), 2), byte_size(payload) - 13] do
        assert {:error, {:png, _reason}} = ImageCheck.validate(binary_part(payload, 0, size))
      end
    end

    test "a corrupt image data stream" do
      rows = <<255>> <> :binary.copy(<<0, 0, 0>>, 2) <> <<0>> <> :binary.copy(<<0, 0, 0>>, 2)
      rejected(png(2, 2, 8, 2, rows), {:png, :invalid_filter_type})

      corrupt = <<0x78, 0x9C, 0xFF, 0xFF, 0xFF, 0xFF, 0x00>>
      rejected(raw_png(2, 2, 8, 2, [chunk("IDAT", corrupt)]), {:png, :corrupt_image_data})
    end

    test "missing image data" do
      rejected(raw_png(2, 2, 8, 2, []), {:png, :missing_idat})
    end

    test "a signature and IHDR followed by garbage" do
      <<head::binary-size(33), _rest::binary>> = fixture("rgb.png")

      for garbage <- [
            :binary.copy(<<0x41>>, 64),
            <<0, 0, 0, 4, "abc1", 0, 0, 0, 0>>,
            :crypto.strong_rand_bytes(64)
          ] do
        assert {:error, {:png, _reason}} = ImageCheck.validate(head <> garbage)
      end

      rejected(head <> chunk("ABCD", "data") <> idat_iend(), {:png, :unknown_critical_chunk})
    end

    test "a missing IEND" do
      payload = fixture("rgb.png")
      rejected(binary_part(payload, 0, byte_size(payload) - 12), {:png, :missing_iend})
    end

    test "wrong amounts of image data" do
      rejected(png(2, 2, 8, 2, :binary.copy(<<0>>, 13)), {:png, :not_enough_image_data})
      rejected(png(2, 2, 8, 2, :binary.copy(<<0>>, 15)), {:png, :too_much_image_data})

      {ihdr, data} = png_parts(fixture("adam7_rgb.png"))

      rejected(
        rebuild_png(ihdr, binary_part(data, 0, byte_size(data) - 1)),
        {:png, :not_enough_image_data}
      )

      rejected(rebuild_png(ihdr, data <> <<0>>), {:png, :too_much_image_data})
      accepted(rebuild_png(ihdr, data))
    end

    test "a highly compressed stream larger than the image is rejected without inflating it all" do
      bomb = :zlib.compress(:binary.copy(<<0>>, 50_000_000))
      rejected(raw_png(1, 1, 8, 0, [chunk("IDAT", bomb)]), {:png, :too_much_image_data})
    end
  end

  describe "PNG damage accepted by providers" do
    test "a bad CRC in an ancillary chunk, a wrong Adler-32 and data after IEND" do
      text = <<0, 0, 0, 3, "tEXt", "a", 0, "b", 0, 0, 0, 0>>

      accepted(
        raw_png(2, 2, 8, 2, [text, chunk("IDAT", :zlib.compress(:binary.copy(<<0>>, 14)))])
      )

      compressed = :zlib.compress(:binary.copy(<<0>>, 14))
      bad_adler = binary_part(compressed, 0, byte_size(compressed) - 4) <> <<1, 2, 3, 4>>
      accepted(raw_png(2, 2, 8, 2, [chunk("IDAT", bad_adler)]))

      accepted(fixture("rgb.png") <> :crypto.strong_rand_bytes(100))
    end

    test "image data split across IDAT chunks, including a split zlib header" do
      {ihdr, data} = png_parts(fixture("adam7_rgba16.png"))
      compressed = :zlib.compress(data)
      parts = for <<byte <- compressed>>, do: chunk("IDAT", <<byte>>)
      accepted(raw_from_ihdr(ihdr, parts))
    end
  end

  describe "PNG structure" do
    test "rejects bad critical CRCs and invalid headers" do
      payload = fixture("rgb.png")
      rejected(put_byte(payload, 29, 0), {:png, :bad_crc})

      rejected(
        raw_png(2, 2, 3, 2, [chunk("IDAT", :zlib.compress(<<0, 0, 0>>))]),
        {:png, :invalid_bit_depth}
      )

      rejected(raw_png(0, 2, 8, 2, []), {:png, :zero_dimension})
      rejected(raw_png(30_000, 30_000, 8, 2, []), :too_many_pixels)
    end

    test "requires a palette for indexed images and consecutive IDAT chunks" do
      rows = <<0, 0, 0, 0>>
      rejected(png(2, 2, 8, 3, rows), {:png, :missing_plte})

      compressed = :zlib.compress(:binary.copy(<<0>>, 14))
      <<first::binary-size(4), second::binary>> = compressed
      text = chunk("tEXt", "a" <> <<0>> <> "b")

      rejected(
        raw_png(2, 2, 8, 2, [chunk("IDAT", first), text, chunk("IDAT", second)]),
        {:png, :non_consecutive_idat}
      )

      accepted(raw_png(2, 2, 8, 2, [chunk("IDAT", first), chunk("IDAT", second), text]))
    end
  end

  describe "GIF" do
    test "rejects truncation and a missing trailer" do
      payload = fixture("animated.gif")

      for size <- [10, 13, 100, div(byte_size(payload), 2), byte_size(payload) - 1] do
        assert {:error, {:gif, _reason}} = ImageCheck.validate(binary_part(payload, 0, size))
      end
    end

    test "rejects invalid structure" do
      <<head::binary-size(6), _size::binary-size(4), rest::binary>> = fixture("static.gif")
      rejected(head <> <<0::16, 7::16-little>> <> rest, {:gif, :zero_dimension})

      screen = "GIF89a" <> <<2::16-little, 2::16-little, 0, 0, 0>>
      rejected(screen <> <<0x3B>>, {:gif, :no_frames})
      frame = <<0x2C, 0::16, 0::16, 2::16-little, 2::16-little, 0>>
      rejected(screen <> frame <> <<12, 1, 0, 0, 0x3B>>, {:gif, :invalid_lzw_code_size})
      rejected(screen <> frame <> <<2, 0, 0x3B>>, {:gif, :empty_frame})
      rejected(screen <> <<0x99>>, {:gif, :invalid_block})
      accepted(screen <> frame <> <<2, 2, 0x4C, 0x01, 0, 0x3B>> <> "trailing data")
    end

    test "reports the union of the logical screen and every frame rectangle" do
      wide = gif(1, 1, [gif_frame(0, 0, 2100, 1)])
      assert {:ok, %{width: 2100, height: 1}} = ImageCheck.validate(wide)
      assert {:ok, %{width: 1, height: 1}} = ImageCheck.header(wide)

      shifted = gif(8, 8, [gif_frame(0, 0, 8, 8), gif_frame(100, 3, 8, 8)])
      assert {:ok, %{width: 108, height: 11}} = ImageCheck.validate(shifted)
    end

    test "applies the pixel limit to the union before reading frame data" do
      huge = gif(8, 8, [gif_frame(0, 0, 65_535, 65_535)])
      rejected(huge, :too_many_pixels)
      assert {:error, :too_many_pixels} = ImageCheck.validate(huge, max_pixels: 4_000_000)
      assert {:ok, %{width: 65_535}} = ImageCheck.validate(huge, max_pixels: :infinity)

      far = gif(8, 8, [gif_frame(0, 0, 8, 8), gif_frame(2_000, 2_000, 8, 8)])
      assert {:error, :too_many_pixels} = ImageCheck.validate(far, max_pixels: 4_000_000)
      assert {:ok, %{width: 2_008, height: 2_008}} = ImageCheck.validate(far)

      # The descriptor alone is enough: no image data follows it.
      descriptor = binary_part(huge, 0, byte_size(huge) - 6)
      rejected(descriptor, :too_many_pixels)
    end

    test "rejects graphic control extensions too short for their fields" do
      for block <- [<<0>>, <<0, 10>>, <<1, 10, 0>>] do
        rejected(
          gif(8, 8, [gif_control(block), gif_frame(0, 0, 8, 8)]),
          {:gif, :invalid_graphic_control}
        )

        rejected(
          gif(8, 8, [gif_frame(0, 0, 8, 8), gif_control(block), gif_frame(0, 0, 8, 8)]),
          {:gif, :invalid_graphic_control}
        )
      end

      for block <- [<<>>, <<0, 10, 0>>, <<1, 10, 0, 0>>, <<1, 10, 0, 0, 0>>] do
        accepted(gif(8, 8, [gif_control(block), gif_frame(0, 0, 8, 8)]))
      end
    end
  end

  describe "WebP" do
    test "rejects truncation" do
      for name <- ["lossy.webp", "animated.webp", "alpha.webp"] do
        payload = fixture(name)

        for size <- [16, 30, div(byte_size(payload), 2), byte_size(payload) - 1] do
          assert {:error, {:webp, _reason}} = ImageCheck.validate(binary_part(payload, 0, size))
        end
      end
    end

    test "accepts trailing data after the RIFF payload" do
      accepted(fixture("lossy.webp") <> "trailing")
    end

    test "rejects chunks outside the RIFF payload and invalid bitstream headers" do
      <<riff::binary-size(4), size::32-little, rest::binary>> = fixture("lossy.webp")
      rejected(riff <> <<size - 8::32-little>> <> rest, {:webp, :chunk_out_of_bounds})

      payload = fixture("lossy.webp")
      rejected(put_byte(payload, 23, 0), {:webp, :invalid_vp8_signature})
      rejected(put_byte(payload, 26, 0) |> put_byte(27, 0), {:webp, :zero_dimension})
      rejected(put_byte(fixture("lossless.webp"), 20, 0), {:webp, :invalid_vp8l_signature})
    end

    test "rejects animation frames outside the canvas" do
      payload = fixture("animated.webp")
      {:ok, offset} = find(payload, "ANMF")
      # Frame width minus one, little-endian 24 bits after the X and Y offsets.
      rejected(put_byte(payload, offset + 8 + 6, 200), {:webp, :frame_outside_canvas})

      vp8 = webp_chunk("VP8 ", piece("lossy.webp", "VP8 "))
      animation = fn x, y -> riff([vp8x(0x02, 20, 12), anim(), anmf(x, y, 10, 6, [vp8])]) end
      accepted(animation.(10, 6))
      rejected(animation.(12, 0), {:webp, :frame_outside_canvas})
      rejected(animation.(0, 8), {:webp, :frame_outside_canvas})
    end

    test "rejects a still canvas that does not match its bitstream" do
      payload = fixture("alpha.webp")
      {:ok, offset} = find(payload, "VP8X")
      rejected(put_byte(payload, offset + 8 + 4, 20), {:webp, :canvas_size_mismatch})
    end

    test "requires the first VP8 partition to end inside the frame data" do
      vp8 = piece("lossy.webp", "VP8 ")
      size = byte_size(vp8)
      accepted(riff([webp_chunk("VP8 ", vp8)]))

      # VP8GetInfo only compares the partition with the whole chunk; the
      # partition starts after the 10-byte header and the token partitions
      # need at least one byte after it.
      for partition <- [size - 1, size - 10, 0] do
        rejected(
          riff([webp_chunk("VP8 ", put_partition(vp8, partition))]),
          {:webp, :invalid_partition_size}
        )
      end

      frame = [webp_chunk("VP8 ", put_partition(vp8, size - 10))]

      rejected(
        riff([vp8x(0x02, 20, 12), anim(), anmf(0, 0, 10, 6, frame)]),
        {:webp, :invalid_partition_size}
      )

      # The pad byte of an odd-sized chunk is part of the decoded frame data.
      odd = put_partition(vp8, size - 9) <> <<0>>
      accepted(riff([webp_chunk("VP8 ", odd)]))

      rejected(
        riff([webp_chunk("VP8 ", odd) |> binary_part(0, 8 + size + 1)]),
        {:webp, :invalid_partition_size}
      )
    end

    test "requires a 10-byte VP8X chunk without reserved flags" do
      [_vp8x | image] = webp_chunks(fixture("alpha.webp"))

      for flags <- [0x11, 0x50, 0x90] do
        rejected(riff([vp8x(flags, 10, 6) | image]), {:webp, :invalid_vp8x_flags})
      end

      rejected(
        riff([webp_chunk("VP8X", <<0x10, 0::24, 9::24-little, 5::24-little, 0, 0>>) | image]),
        {:webp, :invalid_vp8x}
      )

      # libwebp ignores the three reserved bytes.
      accepted(riff([webp_chunk("VP8X", <<0x10, 1, 2, 3, 9::24-little, 5::24-little>>) | image]))
    end

    test "checks the alpha header and data length" do
      vp8 = piece("alpha.webp", "VP8 ")

      with_alpha = fn alpha ->
        riff([vp8x(0x10, 10, 6), webp_chunk("ALPH", alpha), webp_chunk("VP8 ", vp8)])
      end

      raw = :binary.copy(<<255>>, 60)

      accepted(fixture("alpha.webp"))
      accepted(with_alpha.(<<0>> <> raw))
      # All four filters are valid, as is pre-processing 1.
      accepted(with_alpha.(<<0b00011100>> <> raw))
      # The shortest lossless stream: five single-symbol prefix codes.
      accepted(with_alpha.(<<1, 0x88, 0x88, 0x08>>))

      for alpha <- ["", <<0>>, <<1>>, <<0>> <> binary_part(raw, 0, 59), <<1, 0x88, 0x88>>] do
        rejected(with_alpha.(alpha), {:webp, :truncated_alpha})
      end

      for header <- [0b01000000, 0b10000000, 0b00100000, 0b00110000, 2, 3, 0xFF] do
        rejected(with_alpha.(<<header>> <> raw), {:webp, :invalid_alpha_header})
      end
    end

    test "uses ALPH only before a lossy bitstream and with the alpha flag" do
      alpha = piece("alpha.webp", "ALPH")
      vp8 = piece("alpha.webp", "VP8 ")
      vp8l = piece("lossless.webp", "VP8L")
      junk = webp_chunk("JUNK", "ab")

      # Without the flag the demuxer drops ALPH, wherever it is.
      accepted(riff([vp8x(0, 10, 6), webp_chunk("ALPH", ""), webp_chunk("VP8 ", vp8)]))
      accepted(riff([vp8x(0, 10, 6), webp_chunk("VP8 ", vp8), webp_chunk("ALPH", alpha)]))

      accepted(
        riff([vp8x(0x10, 10, 6), junk, webp_chunk("ALPH", alpha), webp_chunk("VP8 ", vp8)])
      )

      rejected(
        riff([vp8x(0x10, 10, 6), webp_chunk("VP8 ", vp8), webp_chunk("ALPH", alpha)]),
        {:webp, :alpha_after_bitstream}
      )

      rejected(
        riff([vp8x(0x10, 10, 6), webp_chunk("VP8L", vp8l), webp_chunk("ALPH", alpha)]),
        {:webp, :alpha_after_bitstream}
      )

      for flags <- [0, 0x10] do
        rejected(
          riff([vp8x(flags, 10, 6), webp_chunk("ALPH", alpha), webp_chunk("VP8L", vp8l)]),
          {:webp, :alpha_with_lossless}
        )

        rejected(
          riff([vp8x(flags, 10, 6), webp_chunk("ALPH", alpha), junk, webp_chunk("VP8 ", vp8)]),
          {:webp, :missing_bitstream}
        )
      end

      rejected(
        riff([webp_chunk("VP8 ", vp8), webp_chunk("ALPH", alpha), webp_chunk("VP8L", vp8l)]),
        {:webp, :alpha_with_lossless}
      )
    end

    test "rejects image chunks outside the single still frame" do
      vp8 = webp_chunk("VP8 ", piece("lossy.webp", "VP8 "))
      junk = webp_chunk("JUNK", "ab")

      for extra <- [
            [vp8],
            [junk, webp_chunk("VP8L", piece("lossless.webp", "VP8L"))],
            [junk, webp_chunk("ALPH", <<0>>)]
          ] do
        rejected(riff([vp8x(0, 10, 6), vp8 | extra]), {:webp, :multiple_bitstreams})
      end

      rejected(riff([vp8x(0, 10, 6), vp8, vp8x(0, 10, 6)]), {:webp, :duplicate_vp8x})
      rejected(riff([vp8x(0, 10, 6), vp8x(0, 10, 6), vp8]), {:webp, :duplicate_vp8x})
      # Simple files end with their first frame.
      accepted(riff([vp8, vp8]))
    end

    test "requires lossless bitstreams to hold at least the shortest image stream" do
      header = binary_part(piece("lossless.webp", "VP8L"), 0, 5)
      accepted(riff([webp_chunk("VP8L", header <> <<0x88, 0x88, 0x08>>)]))
      rejected(riff([webp_chunk("VP8L", header <> <<0x88>>)]), {:webp, :truncated_bitstream})

      # As for VP8, the pad byte of an odd-sized chunk is read as frame data.
      unpadded = <<"VP8L", 7::32-little, header::binary, 0x88, 0x88>>
      rejected(riff([unpadded]), {:webp, :truncated_bitstream})
      accepted(riff([unpadded <> <<0x08>>]))
    end

    test "requires ANIM before the first ANMF" do
      [vp8x, {"ANIM", _} = anim, {"ANMF", _} = first | others] =
        webp_chunks(fixture("animated.webp"))

      accepted(riff([vp8x, anim, first | others]))
      rejected(riff([vp8x, first, anim | others]), {:webp, :anmf_before_anim})
    end

    test "accepts image chunks in animations only as the frame data of ANMF" do
      vp8 = webp_chunk("VP8 ", piece("lossy.webp", "VP8 "))
      junk = webp_chunk("JUNK", "ab")
      animation = fn chunks -> riff([vp8x(0x02, 20, 12), anim() | chunks]) end

      accepted(animation.([anmf(0, 0, 10, 6, [vp8]), anmf(10, 6, 10, 6, [vp8, junk])]))
      rejected(animation.([anmf(0, 0, 10, 6, [vp8]), vp8]), {:webp, :bitstream_outside_frame})

      rejected(
        riff([vp8x(0x02, 20, 12), vp8, anim(), anmf(0, 0, 10, 6, [vp8])]),
        {:webp, :bitstream_outside_frame}
      )

      rejected(animation.([anmf(0, 0, 10, 6, [vp8, vp8])]), {:webp, :bitstream_outside_frame})
      rejected(animation.([anmf(0, 0, 10, 6, [junk, vp8])]), {:webp, :missing_bitstream})

      rejected(
        animation.([anmf(0, 0, 10, 6, [vp8, anmf(0, 0, 10, 6, [vp8])])]),
        {:webp, :invalid_anmf}
      )

      rejected(
        animation.([anmf(0, 0, 10, 6, [vp8]), vp8x(0x02, 20, 12)]),
        {:webp, :duplicate_vp8x}
      )
    end

    test "checks the alpha of animation frames regardless of the alpha flag" do
      alpha = webp_chunk("ALPH", piece("alpha.webp", "ALPH"))
      vp8 = webp_chunk("VP8 ", piece("alpha.webp", "VP8 "))

      animation = fn flags, frame ->
        riff([vp8x(flags, 20, 12), anim(), anmf(0, 0, 10, 6, frame)])
      end

      accepted(animation.(0x12, [alpha, vp8]))

      rejected(
        animation.(0x02, [webp_chunk("ALPH", <<0, 1, 2>>), vp8]),
        {:webp, :truncated_alpha}
      )

      rejected(animation.(0x12, [webp_chunk("ALPH", <<3>>), vp8]), {:webp, :invalid_alpha_header})
      rejected(animation.(0x12, [vp8, alpha]), {:webp, :alpha_after_bitstream})
    end
  end

  ## JPEG helpers

  defp segment(payload, marker), do: payload |> segments() |> List.keyfind(marker, 0) |> elem(1)

  defp last_segment(payload, marker) do
    payload |> segments() |> Enum.filter(&(elem(&1, 0) == marker)) |> List.last() |> elem(1)
  end

  # {marker, {offset_of_ff, length}} for header segments and all SOS segments.
  defp segments(payload), do: segments(payload, 2, [])

  defp segments(payload, offset, acc) when offset + 4 <= byte_size(payload) do
    <<_::binary-size(^offset), 0xFF, marker, length::16, _::binary>> = payload
    acc = [{marker, {offset, length}} | acc]

    cond do
      marker == 0xD9 ->
        Enum.reverse(acc)

      marker == 0xDA ->
        case next_marker(payload, offset + 2 + length) do
          nil -> Enum.reverse(acc)
          next -> segments(payload, next, acc)
        end

      true ->
        segments(payload, offset + 2 + length, acc)
    end
  end

  defp segments(_payload, _offset, acc), do: Enum.reverse(acc)

  defp next_marker(payload, offset) when offset + 1 < byte_size(payload) do
    case :binary.at(payload, offset) == 0xFF and :binary.at(payload, offset + 1) do
      byte when byte in 0xC0..0xFE and byte not in 0xD0..0xD7 -> offset
      _other -> next_marker(payload, offset + 1)
    end
  end

  defp next_marker(_payload, _offset), do: nil

  defp scan_data_range(payload) do
    {offset, length} = segment(payload, 0xDA)
    {offset + 2 + length, byte_size(payload)}
  end

  defp put_frame_size(payload, width, height) do
    {offset, _length} = segment(payload, 0xC0)
    <<head::binary-size(^offset + 5), _size::32, tail::binary>> = payload
    head <> <<height::16, width::16>> <> tail
  end

  defp replace_marker(payload, from, to) do
    {offset, _length} = segment(payload, from)
    put_byte(payload, offset + 1, to)
  end

  defp overflow_first_huffman_table(payload) do
    {offset, _length} = segment(payload, 0xC4)
    counts_offset = offset + 5
    counts = :binary.bin_to_list(binary_part(payload, counts_offset, 16))
    donor = Enum.find_index(counts, &(&1 >= 2))
    counts = counts |> List.update_at(0, &(&1 + 2)) |> List.update_at(donor, &(&1 - 2))
    <<head::binary-size(^counts_offset), _::binary-size(16), tail::binary>> = payload
    head <> :binary.list_to_bin(counts) <> tail
  end

  ## PNG helpers

  defp png(width, height, depth, color, rows) do
    raw_png(width, height, depth, color, [chunk("IDAT", :zlib.compress(rows))])
  end

  defp raw_png(width, height, depth, color, chunks) do
    raw_from_ihdr(<<width::32, height::32, depth, color, 0, 0, 0>>, chunks)
  end

  defp raw_from_ihdr(ihdr, chunks) do
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
      chunk("IHDR", ihdr) <> IO.iodata_to_binary(chunks) <> chunk("IEND", "")
  end

  defp idat_iend, do: chunk("IDAT", :zlib.compress(<<0>>)) <> chunk("IEND", "")

  defp png_parts(
         <<_signature::binary-size(8), 13::32, "IHDR", ihdr::binary-size(13), _crc::32,
           rest::binary>>
       ) do
    {ihdr, :zlib.uncompress(idat_data(rest, []))}
  end

  defp idat_data(<<length::32, type::binary-size(4), rest::binary>>, acc) do
    <<data::binary-size(^length), _crc::32, rest::binary>> = rest
    acc = if type == "IDAT", do: [acc, data], else: acc
    if type == "IEND", do: IO.iodata_to_binary(acc), else: idat_data(rest, acc)
  end

  defp rebuild_png(ihdr, data), do: raw_from_ihdr(ihdr, [chunk("IDAT", :zlib.compress(data))])

  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end

  ## GIF helpers

  defp gif(width, height, blocks) do
    "GIF89a" <>
      <<width::16-little, height::16-little, 0, 0, 0>> <> IO.iodata_to_binary(blocks) <> <<0x3B>>
  end

  # A frame without a local color table and a two-byte LZW stream.
  defp gif_frame(left, top, width, height) do
    <<0x2C, left::16-little, top::16-little, width::16-little, height::16-little, 0, 2, 2, 0x4C,
      0x01, 0>>
  end

  defp gif_control(<<>>), do: <<0x21, 0xF9, 0>>
  defp gif_control(block), do: <<0x21, 0xF9, byte_size(block)>> <> block <> <<0>>

  ## WebP helpers

  defp webp_chunks(<<"RIFF", _size::32-little, "WEBP", chunks::binary>>), do: split_chunks(chunks)

  defp split_chunks(<<>>), do: []

  defp split_chunks(
         <<fourcc::binary-size(4), size::32-little, data::binary-size(size), rest::binary>>
       ) do
    pad = rem(size, 2)
    <<_pad::binary-size(^pad), rest::binary>> = rest
    [{fourcc, data} | split_chunks(rest)]
  end

  defp piece(name, fourcc),
    do: name |> fixture() |> webp_chunks() |> List.keyfind(fourcc, 0) |> elem(1)

  defp encode_chunk({fourcc, data}), do: webp_chunk(fourcc, data)
  defp encode_chunk(chunk) when is_binary(chunk), do: chunk

  defp webp_chunk(fourcc, data) do
    <<fourcc::binary, byte_size(data)::32-little, data::binary,
      0::size(rem(byte_size(data), 2) * 8)>>
  end

  defp riff(chunks) do
    body = "WEBP" <> IO.iodata_to_binary(Enum.map(chunks, &encode_chunk/1))
    <<"RIFF", byte_size(body)::32-little, body::binary>>
  end

  defp vp8x(flags, width, height),
    do: webp_chunk("VP8X", <<flags, 0::24, width - 1::24-little, height - 1::24-little>>)

  defp anim, do: webp_chunk("ANIM", <<0::32, 0::16>>)

  defp anmf(x, y, width, height, frame) do
    header =
      <<div(x, 2)::24-little, div(y, 2)::24-little, width - 1::24-little, height - 1::24-little,
        100::24-little, 0>>

    webp_chunk("ANMF", header <> IO.iodata_to_binary(frame))
  end

  defp put_partition(<<b0, b1, b2, rest::binary>>, size) do
    import Bitwise
    bits = ((b0 ||| b1 <<< 8 ||| b2 <<< 16) &&& 0x1F) ||| size <<< 5
    <<bits::24-little, rest::binary>>
  end

  ## Binary helpers

  defp put_byte(payload, offset, byte) do
    <<head::binary-size(^offset), _old, tail::binary>> = payload
    <<head::binary, byte, tail::binary>>
  end

  defp remove(payload, offset, length) do
    <<head::binary-size(^offset), _::binary-size(^length), tail::binary>> = payload
    head <> tail
  end

  defp insert(payload, offset, data) do
    <<head::binary-size(^offset), tail::binary>> = payload
    head <> data <> tail
  end

  defp find(payload, pattern) do
    case :binary.match(payload, pattern) do
      {offset, _length} -> {:ok, offset}
      :nomatch -> :error
    end
  end
end
