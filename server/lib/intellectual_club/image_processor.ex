defmodule IntellectualClub.ImageProcessor do
  @moduledoc """
  Rules for images sent natively to model providers.

  Images are never decoded, resized or re-encoded. `validate/1` is the cheap
  structural check of `ImageCheck`; its result is remembered per payload SHA-256
  by `IntellectualClub.Files.ImageVerdicts` under `check_version/0`. Request limits
  are applied separately with `check_limits/2`, so verdicts do not depend on them.
  """

  # Bump whenever the ImageCheck rules or options used by validate/1 change, so
  # that remembered verdicts are recomputed.
  @check_version 2

  @max_edge_px 2_000
  # Anthropic rejects base64 image data above 10 MiB; 4/3 * 7_864_320 = 10_485_760.
  @max_payload_bytes 7_864_320

  @spec check_version() :: pos_integer()
  def check_version, do: @check_version

  @spec max_edge_px() :: pos_integer()
  def max_edge_px, do: @max_edge_px

  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @doc "Reads the format and dimensions from the headers only."
  @spec header(binary()) :: {:ok, ImageCheck.info()} | {:error, ImageCheck.reason()}
  def header(payload) when is_binary(payload), do: ImageCheck.header(payload)

  @doc "Structural validation with the package's default pixel budget."
  @spec validate(binary()) :: {:ok, ImageCheck.info()} | {:error, ImageCheck.reason()}
  def validate(payload) when is_binary(payload), do: ImageCheck.validate(payload)

  @doc "Checks the request limits for an image of the given size and byte length."
  @spec check_limits(%{width: pos_integer(), height: pos_integer()}, non_neg_integer()) ::
          :ok | {:error, :image_dimensions_exceed_limit | :image_bytes_exceed_limit}
  def check_limits(%{width: width, height: height}, size_bytes) when is_integer(size_bytes) do
    cond do
      max(width, height) > @max_edge_px -> {:error, :image_dimensions_exceed_limit}
      size_bytes > @max_payload_bytes -> {:error, :image_bytes_exceed_limit}
      true -> :ok
    end
  end
end
