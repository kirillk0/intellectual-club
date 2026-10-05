defmodule IntellectualClub.FilesFixtures do
  @moduledoc """
  Fixtures for stored files and multipart uploads.
  """

  import IntellectualClub.Fixtures

  @doc """
  Stores a file through `IntellectualClub.Files.create_from_upload/1`.
  Defaults: `filename: "file.txt"`, `mime_type: "text/plain"`, `payload: "content"`.
  """
  def create_file!(attrs \\ %{}) do
    defaults = %{filename: "file.txt", mime_type: "text/plain", payload: "content"}
    {:ok, file} = IntellectualClub.Files.create_from_upload(merge_attrs(defaults, attrs))
    file
  end

  @doc """
  Writes `body` to a temporary file and returns a `%Plug.Upload{}` for it, as
  Plug builds for multipart requests. The file is removed when the test exits.
  """
  def plug_upload(filename, content_type, body) do
    safe_name = String.replace(filename, ~r/[^a-zA-Z0-9_.-]/, "_")

    path =
      Path.join(System.tmp_dir!(), "ic-upload-#{System.unique_integer([:positive])}-#{safe_name}")

    File.write!(path, body)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end
end
