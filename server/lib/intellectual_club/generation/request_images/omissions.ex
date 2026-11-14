defmodule IntellectualClub.Generation.RequestImages.Omissions do
  @moduledoc """
  Text that replaces a request image which is not sent natively.

  The text names the file and its `file_id` (the source file external id), so the
  model can still reach the file with file tools.
  """

  alias IntellectualClub.ImageProcessor

  @unavailable "[Image omitted: attached file could not be validated as an image.]"
  @max_filename_length 200

  @type kind :: :invalid | :provider_rejected | :over_limit

  @doc "Text for a file that cannot be loaded in the current scope."
  @spec unavailable() :: String.t()
  def unavailable, do: @unavailable

  @doc """
  Text for an image omitted for `kind`. `dimensions` is any map with `:width`
  and `:height`, or `nil` when they are unknown.
  """
  @spec text(
          kind(),
          %{filename: String.t(), size_bytes: non_neg_integer()},
          String.t(),
          map() | nil
        ) ::
          String.t()
  def text(kind, file, file_external_id, dimensions) do
    details =
      ["file_id=#{file_external_id}", pixels(dimensions), size(file.size_bytes)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "[Image omitted: #{filename(file.filename)} (#{details}) #{reason(kind)}. " <>
      "The file remains available to file tools.]"
  end

  defp reason(:invalid), do: "could not be validated as an image"
  defp reason(:provider_rejected), do: "was rejected by the model provider"

  defp reason(:over_limit) do
    "exceeds the image input limits of #{ImageProcessor.max_edge_px()} px per side and " <>
      "#{size(ImageProcessor.max_payload_bytes())}"
  end

  defp pixels(%{width: width, height: height}) when is_integer(width) and is_integer(height),
    do: "#{width}x#{height} px"

  defp pixels(_dimensions), do: nil

  defp size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MB"

  defp size(bytes) when is_integer(bytes), do: "#{div(bytes + 1023, 1024)} KB"
  defp size(_bytes), do: nil

  defp filename(name) when is_binary(name),
    do: inspect(String.slice(name, 0, @max_filename_length))

  defp filename(_name), do: inspect("image")
end
