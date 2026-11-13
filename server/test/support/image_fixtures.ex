defmodule IntellectualClub.ImageFixtures do
  @moduledoc """
  Small image payloads for upload, media and provider request tests.

  Imported by `IntellectualClub.DataCase` and `IntellectualClubWeb.ConnCase`.
  """

  @jpeg_2x1 Base.decode64!(
              "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAABAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD8qqKKKAP/2Q=="
            )

  @png_1x1 <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
             8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 248, 15,
             4, 0, 9, 251, 3, 253, 251, 94, 107, 43, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
             130>>

  @doc "A 2x1 baseline JPEG."
  def jpeg_2x1, do: @jpeg_2x1

  @doc "A valid 1x1 RGBA PNG (the smallest accepted image payload)."
  def png_1x1, do: @png_1x1

  @doc "A PNG with a valid header but an incomplete IDAT chunk."
  def truncated_png, do: binary_part(png(20, 10), 0, 45)

  @doc "A 3000x1500 PNG, large enough to be downscaled by image processing."
  def oversized_png, do: png(3000, 1500)

  @doc "An RGB PNG header without pixel data, for validation limit tests."
  def png_header(width, height) do
    header = <<width::32, height::32, 8, 2, 0, 0, 0>>
    <<137, 80, 78, 71, 13, 10, 26, 10>> <> chunk("IHDR", header)
  end

  @doc "An RGB PNG of the given size with black pixels."
  def png(width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    row = <<0>> <> :binary.copy(<<0, 0, 0>>, width)
    pixels = :binary.copy(row, height)

    png_header(width, height) <>
      chunk("IDAT", :zlib.compress(pixels)) <>
      chunk("IEND", <<>>)
  end

  defp chunk(type, payload) do
    checksum = :erlang.crc32(type <> payload)
    <<byte_size(payload)::32, type::binary-size(4), payload::binary, checksum::32>>
  end
end
