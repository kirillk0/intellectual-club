defmodule IntellectualClub.ImageProcessorTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.ImageFixtures
  alias IntellectualClub.ImageProcessor

  test "shrinks an image to the requested maximum edge" do
    source = ImageFixtures.png(300, 150)

    assert {:ok, resized, "image/png"} =
             ImageProcessor.resize_down(source, "image/png", 64)

    assert {"image/png", width, height, _variant} = ExImageInfo.info(resized)
    assert max(width, height) <= 64
    assert width == 64
    assert height == 32
  end

  test "does not enlarge a smaller image" do
    source = ImageFixtures.png(20, 10)

    assert {:ok, resized, "image/png"} =
             ImageProcessor.resize_down(source, "image/png", 64)

    assert {"image/png", 20, 10, _variant} = ExImageInfo.info(resized)
  end

  describe "validate/1" do
    test "accepts complete PNG and JPEG payloads" do
      for payload <- [
            ImageFixtures.png_1x1(),
            ImageFixtures.png(20, 10),
            ImageFixtures.jpeg_2x1()
          ] do
        assert :ok = ImageProcessor.validate(payload)
      end
    end

    test "rejects non-image payloads" do
      assert {:error, :invalid_image_payload} = ImageProcessor.validate("not an image")
    end

    unless match?({:win32, _name}, :os.type()) do
      test "rejects truncated pixel data even when the header is valid and no resize is needed" do
        payload = ImageFixtures.truncated_png()
        assert {"image/png", 20, 10, _} = ExImageInfo.info(payload)
        assert {:error, :invalid_image_payload} = ImageProcessor.validate(payload)
      end

      test "forces decoding when loading a truncated image succeeds lazily" do
        source = ImageFixtures.oversized_png()
        payload = binary_part(source, 0, byte_size(source) - 50)
        assert {:ok, _lazy_image} = Image.from_binary(payload, fail_on: :error)
        assert {:error, :invalid_image_payload} = ImageProcessor.validate(payload)
      end

      test "rejects truncated JPEG scan data" do
        source = ImageFixtures.jpeg_2x1()
        payload = binary_part(source, 0, byte_size(source) - 10)
        assert {"image/jpeg", 2, 1, _} = ExImageInfo.info(payload)
        assert {:error, :invalid_image_payload} = ImageProcessor.validate(payload)
      end

      test "accepts complete animated GIF images" do
        payload =
          Base.decode64!(
            "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"
          )

        assert :ok = ImageProcessor.validate(payload)
      end

      test "rejects a malformed later GIF frame even when the first frame decodes" do
        payload =
          Base.decode64!(
            "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAMBgABCAQQEAA7"
          )

        assert {:error, :invalid_image_payload} = ImageProcessor.validate(payload)
      end

      test "accepts complete animated WEBP images" do
        payload =
          Base.decode64!(
            "UklGRsQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAABBTk1GSgAAAAAAAAAAAAEAAAEAAGQAAAJWUDggMgAAADABAJ0BKgIAAgABQCYloAADcAD+8ut///mwP/bz/wR6Af//0uD//pcH//S4P/SkAAAAQU5NRkYAAAAAAAAAAAABAAABAABkAAAAVlA4IC4AAAA0AQCdASoCAAIAAAAmJaAAA3AA/vtV4///S4P/+lwf/9Lg/9Lg//rV5Vesq6AA"
          )

        assert :ok = ImageProcessor.validate(payload)
      end

      test "rejects images over the pixel budget before decoding their data" do
        oversized = ImageFixtures.png_header(100_001, 1_000)
        assert {:error, :image_pixel_limit_exceeded} = ImageProcessor.validate(oversized)
      end
    end
  end

  # Windows resizes through the vips CLI, one short-lived process per image.
  unless match?({:win32, _name}, :os.type()) do
    @tag :whitebox
    test "resizing leaves no libvips operations cached in native memory" do
      source = ImageFixtures.png(300, 150)

      assert {:ok, _resized, "image/png"} =
               ImageProcessor.resize_down(source, "image/png", 64)

      assert Vix.Vips.cache_get_max() == 0
      assert Vix.Vips.cache_get_max_mem() == 0
      assert Vix.Vips.cache_get_max_files() == 0
    end
  end
end
