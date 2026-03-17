defmodule IntellectualClubWeb.RequestLimits do
  @moduledoc false

  alias IntellectualClubWeb.Bff.ChatUploadPolicy

  # Keep this aligned with the default attachment limit and leave room for
  # multipart overhead.
  @max_body_length_bytes ChatUploadPolicy.default_max_file_size_bytes() + 10 * 1024 * 1024

  def max_body_length_bytes, do: @max_body_length_bytes
end
