defmodule IntellectualClub.ImageProcessorTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.ImageFixtures
  alias IntellectualClub.ImageProcessor

  describe "validate/1" do
    test "accepts complete PNG, JPEG, GIF and WebP payloads without decoding them" do
      for {payload, mime_type, width, height} <- [
            {ImageFixtures.png_1x1(), "image/png", 1, 1},
            {ImageFixtures.png(20, 10), "image/png", 20, 10},
            {ImageFixtures.oversized_png(), "image/png", 3_000, 1_500},
            {ImageFixtures.jpeg_2x1(), "image/jpeg", 2, 1},
            {animated_gif(), "image/gif", 2, 2},
            {animated_webp(), "image/webp", 2, 2}
          ] do
        assert {:ok, %{mime_type: ^mime_type, width: ^width, height: ^height}} =
                 ImageProcessor.validate(payload)
      end
    end

    test "rejects non-image payloads and formats providers do not accept" do
      assert {:error, :unknown_format} = ImageProcessor.validate("not an image")
      assert {:error, {:unsupported_format, :bmp}} = ImageProcessor.validate("BM" <> <<0::64>>)
    end

    test "rejects truncated PNG data even when the header is valid" do
      payload = ImageFixtures.truncated_png()
      assert {:ok, %{width: 20, height: 10}} = ImageProcessor.header(payload)
      assert {:error, {:png, _reason}} = ImageProcessor.validate(payload)
    end

    test "accepts a JPEG truncated inside its scan data but not inside its headers" do
      source = ImageFixtures.jpeg_2x1()
      {scan_header, 2} = :binary.match(source, <<0xFF, 0xDA>>)
      scan_data = scan_header + 2 + 12

      assert {:ok, %{mime_type: "image/jpeg"}} =
               ImageProcessor.validate(binary_part(source, 0, scan_data + 1))

      assert {:error, {:jpeg, :segment_out_of_bounds}} =
               ImageProcessor.validate(binary_part(source, 0, scan_data - 1))
    end

    test "rejects a GIF frame with an invalid LZW code size" do
      payload =
        Base.decode64!(
          "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAMBgABCAQQEAA7"
        )

      assert {:error, {:gif, :invalid_lzw_code_size}} = ImageProcessor.validate(payload)
    end

    test "rejects declared sizes over the pixel budget before reading image data" do
      oversized = ImageFixtures.png_header(100_001, 1_001)
      assert {:error, :too_many_pixels} = ImageProcessor.validate(oversized)
    end
  end

  describe "check_limits/2" do
    test "limits the longest edge to 2000 px and the payload so its base64 fits 10 MiB" do
      assert ImageProcessor.max_edge_px() == 2_000
      assert div(ImageProcessor.max_payload_bytes() * 4, 3) == 10 * 1024 * 1024
      max_bytes = ImageProcessor.max_payload_bytes()

      assert :ok = ImageProcessor.check_limits(%{width: 2_000, height: 2_000}, max_bytes)

      assert {:error, :image_dimensions_exceed_limit} =
               ImageProcessor.check_limits(%{width: 1, height: 2_001}, 10)

      assert {:error, :image_bytes_exceed_limit} =
               ImageProcessor.check_limits(%{width: 10, height: 10}, max_bytes + 1)
    end
  end

  defp animated_gif do
    Base.decode64!(
      "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"
    )
  end

  defp animated_webp do
    Base.decode64!(
      "UklGRsQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAABBTk1GSgAAAAAAAAAAAAEAAAEAAGQAAAJWUDggMgAAADABAJ0BKgIAAgABQCYloAADcAD+8ut///mwP/bz/wR6Af//0uD//pcH//S4P/SkAAAAQU5NRkYAAAAAAAAAAAABAAABAABkAAAAVlA4IC4AAAA0AQCdASoCAAIAAAAmJaAAA3AA/vtV4///S4P/+lwf/9Lg/9Lg//rV5Vesq6AA"
    )
  end
end
