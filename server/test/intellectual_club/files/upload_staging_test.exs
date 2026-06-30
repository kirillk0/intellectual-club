defmodule IntellectualClub.Files.UploadStagingTest do
  @moduledoc """
  Tests for temporary upload staging path helpers.
  """

  use ExUnit.Case, async: false

  alias IntellectualClub.Files.UploadStaging

  setup do
    previous_path = Application.get_env(:intellectual_club, :upload_staging_path)

    staging_path =
      Path.join(
        System.tmp_dir!(),
        "intellectual_club_upload_staging_test_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:intellectual_club, :upload_staging_path, staging_path)

    on_exit(fn ->
      if previous_path do
        Application.put_env(:intellectual_club, :upload_staging_path, previous_path)
      else
        Application.delete_env(:intellectual_club, :upload_staging_path)
      end

      File.rm_rf(staging_path)
    end)

    {:ok, staging_path: staging_path}
  end

  test "uses the configured staging root and creates scoped paths", %{
    staging_path: staging_path
  } do
    assert UploadStaging.root_path() == staging_path
    assert :ok = UploadStaging.ensure_root()
    assert File.dir?(staging_path)

    assert :ok = UploadStaging.ensure_scope(:chat)
    assert File.dir?(Path.join(staging_path, "chat"))

    assert UploadStaging.chat_upload_path("upload-id") ==
             Path.join([staging_path, "chat", "upload-id.part"])

    assert {:ok, outlet_path} = UploadStaging.new_temp_path(:outlet)
    assert Path.dirname(outlet_path) == Path.join(staging_path, "outlet")
    assert File.dir?(Path.dirname(outlet_path))
    refute File.exists?(outlet_path)
  end

  test "rejects invalid scopes" do
    assert {:error, :invalid_scope} = UploadStaging.ensure_scope(:unknown)
    assert {:error, :invalid_scope} = UploadStaging.new_temp_path(:unknown)
  end
end
