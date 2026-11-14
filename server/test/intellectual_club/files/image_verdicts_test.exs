defmodule IntellectualClub.Files.ImageVerdictsTest do
  @moduledoc """
  `IntellectualClub.Files.ImageVerdicts`: structural verdicts remembered per
  payload SHA-256, rule-version recomputation and batch loading.
  """

  use IntellectualClub.DataCase, async: true

  import IntellectualClub.SqlCapture, only: [capture_queries: 2]

  alias IntellectualClub.Files.{ImageVerdict, ImageVerdicts}
  alias IntellectualClub.ImageProcessor

  describe "ensure/3" do
    test "computes a verdict once and returns the remembered one afterwards" do
      file = create_file!(filename: "a.png", mime_type: "image/png", payload: png(3, 2))
      payload = png(3, 2)

      assert {:ok, verdict, memo} = ImageVerdicts.ensure(file, payload, %{})
      assert %{status: :valid, mime_type: "image/png", width: 3, height: 2} = verdict
      assert verdict.check_version == ImageProcessor.check_version()
      assert memo == %{file.sha256 => verdict}

      {result, queries} = callers_queries(fn -> ImageVerdicts.ensure(file, payload, memo) end)
      assert {:ok, ^verdict, ^memo} = result
      assert queries == []

      assert {:ok, remembered, _memo} = ImageVerdicts.ensure(file, payload, %{})
      assert fields(remembered) == fields(verdict)
      assert fields(stored(file.sha256)) == fields(verdict)
    end

    test "records invalid payloads with a short reason and no input data" do
      payload = truncated_png()
      file = create_file!(filename: "broken.png", mime_type: "image/png", payload: payload)

      assert {:ok, %{status: :invalid, reason: "png:" <> _, mime_type: nil, width: nil}, _memo} =
               ImageVerdicts.ensure(file, payload, %{})

      assert ImageVerdicts.classify(stored(file.sha256)) == :invalid
    end

    test "recomputes verdicts of older rules" do
      payload = png_1x1()
      file = create_file!(filename: "a.png", mime_type: "image/png", payload: payload)

      image_verdict!(file.sha256,
        check_version: 0,
        status: :invalid,
        mime_type: nil,
        width: nil,
        height: nil,
        reason: "old"
      )

      assert ImageVerdicts.classify(stored(file.sha256)) == :unchecked
      refute ImageVerdicts.current?(stored(file.sha256))
      assert {:ok, verdict, _memo} = ImageVerdicts.ensure(file, payload, %{})
      assert %{status: :valid, reason: nil, width: 1} = verdict
      assert ImageVerdicts.current?(verdict)
      assert fields(stored(file.sha256)) == fields(verdict)
    end

    test "refuses payloads whose size differs from the file" do
      file = create_file!(filename: "a.png", mime_type: "image/png", payload: png_1x1())

      assert {:error, :image_verdict_payload_mismatch} =
               ImageVerdicts.ensure(file, png_1x1() <> "x", %{})
    end
  end

  describe "load/2 and fetch/2" do
    test "loads all unknown hashes with one query and memoizes missing rows" do
      known = image_verdict!(sha("a"))
      missing = sha("b")

      {result, queries} =
        callers_queries(fn ->
          ImageVerdicts.load([known.sha256, missing, known.sha256, "bad"])
        end)

      assert {:ok, memo} = result
      assert Map.keys(memo) |> Enum.sort() == Enum.sort([known.sha256, missing])
      assert fields(memo[known.sha256]) == fields(known)
      assert memo[missing] == nil
      assert length(queries) == 1

      {result, queries} = callers_queries(fn -> ImageVerdicts.fetch(missing, memo) end)
      assert {:ok, nil, ^memo} = result
      assert queries == []
    end
  end

  defp sha(char), do: String.duplicate(char, 64)

  defp callers_queries(fun), do: capture_queries(fun, processes: :callers)

  defp fields(verdict),
    do: Map.take(verdict, Map.keys(ImageVerdict.__struct__()) -- [:__meta__, :__metadata__])

  defp stored(sha256), do: Ash.get!(ImageVerdict, sha256, authorize?: false)
end
