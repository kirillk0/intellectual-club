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
