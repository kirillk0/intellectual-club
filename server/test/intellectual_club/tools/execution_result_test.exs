defmodule IntellectualClub.Tools.ExecutionResultTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.ExecutionResult

  test "normalizes known attachment fields to atom keys" do
    raw = %{"file_id" => "opaque", "nested" => %{"mime_type" => "opaque/type"}}

    result =
      ExecutionResult.normalize(%{
        "text" => "done",
        "raw" => raw,
        "media" => [
          %{
            "file_id" => 42,
            "file_external_id" => "file-external-id",
            "filename" => "image.png",
            "mime_type" => "image/png",
            "size_bytes" => 128,
            "sha256" => "digest",
            "is_image" => true,
            "provider" => %{"file_id" => "provider-value"}
          }
        ],
        "artifacts" => [%{"file_id" => 43, "filename" => "result.txt"}]
      })

    assert result.raw == raw

    assert [media] = result.media
    assert media.file_id == 42
    assert media.file_external_id == "file-external-id"
    assert media.filename == "image.png"
    assert media.mime_type == "image/png"
    assert media.size_bytes == 128
    assert media.sha256 == "digest"
    assert media.is_image == true
    assert media["provider"] == %{"file_id" => "provider-value"}

    refute Enum.any?(
             ~w(file_id file_external_id filename mime_type size_bytes sha256 is_image),
             &Map.has_key?(media, &1)
           )

    assert result.artifacts == [%{file_id: 43, filename: "result.txt"}]
  end

  test "prefers an existing atom field when both key styles are present" do
    result =
      ExecutionResult.normalize(%ExecutionResult{
        media: [%{:file_id => 1, "file_id" => 2}],
        artifacts: []
      })

    assert result.media == [%{file_id: 1}]
  end

  test "filters invalid attachment entries without changing opaque raw values" do
    result =
      ExecutionResult.normalize(%{
        raw: :opaque,
        media: [nil, "image", %{"filename" => "image.png"}],
        artifacts: :invalid
      })

    assert result.raw == %{"raw" => :opaque}
    assert result.media == [%{filename: "image.png"}]
    assert result.artifacts == []
  end
end
