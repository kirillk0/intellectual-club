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
end
