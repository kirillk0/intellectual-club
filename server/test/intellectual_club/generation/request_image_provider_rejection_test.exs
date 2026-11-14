defmodule IntellectualClub.Generation.RequestImageProviderRejectionTest do
  @moduledoc """
  `IntellectualClub.Generation.RequestImages.ProviderRejection`: recognizing
  provider errors that reject a request image, selecting the images to blame
  among those an attempt sent and the diagnostic stored with the rejection.
  """

  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.RequestImages.ProviderRejection
  alias IntellectualClub.TestSupport.ProviderImageRejections

  describe "image_rejection?/1" do
    for {name, meta} <- ProviderImageRejections.rejections() do
      @meta meta
      test "recognizes #{name}" do
        assert ProviderRejection.image_rejection?(@meta)
      end
    end

    for {name, meta} <- ProviderImageRejections.unrelated() do
      @meta meta
      test "ignores #{name}" do
        refute ProviderRejection.image_rejection?(@meta)
      end
    end

    test "an error inside a completed response is recognized from its raw message" do
      raw =
        ~s({"type":"error","error":{"type":"invalid_request_error","message":"Could not process image"}})

      meta = %{
        status_code: nil,
        error_kind: "provider",
        error_text: "Provider returned error",
        raw_response: %{
          "error" => %{"code" => "invalid_request_error", "metadata" => %{"raw" => raw}}
        }
      }

      assert ProviderRejection.image_rejection?(meta)
      refute ProviderRejection.image_rejection?(%{meta | error_kind: "network"})
    end

    test "rate limits, missing statuses and malformed metadata are not image rejections" do
      {_name, meta} = hd(ProviderImageRejections.rejections())

      refute ProviderRejection.image_rejection?(%{meta | status_code: 429})
      refute ProviderRejection.image_rejection?(%{meta | raw_response: nil})
      refute ProviderRejection.image_rejection?(%{meta | raw_response: "plain text"})
      refute ProviderRejection.image_rejection?(%{})
      refute ProviderRejection.image_rejection?(nil)
    end
  end

  describe "suspects/1" do
    test "blames the sent images the configuration has not accepted before" do
      sent = [sent("cc", false), sent("aa", true), sent("bb", false), sent("cc", false)]
      assert ProviderRejection.suspects(sent) == {["bb", "cc"], false}
    end

    test "blames every sent image as a fallback when all were accepted before" do
      sent = [sent("bb", true), sent("aa", true)]
      assert ProviderRejection.suspects(sent) == {["aa", "bb"], true}
    end

    test "blames nothing when nothing was sent" do
      assert ProviderRejection.suspects([]) == {[], false}
    end
  end

  describe "details/2" do
    test "names the provider and the image error rather than a generic message" do
      raw = "messages.0.content.1.image.source.base64:\n  image exceeds 10 MB maximum"

      meta = %{
        status_code: 400,
        error_text: "Provider returned error",
        raw_response: %{"error" => %{"metadata" => %{"raw" => raw}}}
      }

      assert ProviderRejection.details("openrouter", meta) ==
               "openrouter: messages.0.content.1.image.source.base64: image exceeds 10 MB maximum"

      long = %{error_text: "Could not process image " <> String.duplicate("x", 1_000)}

      assert "anthropic: Could not process image x" <> _rest =
               details = ProviderRejection.details("anthropic", long)

      assert String.length(details) == String.length("anthropic: ") + 300
    end
  end

  defp sent(sha256, accepted?), do: %{sha256: sha256, accepted?: accepted?}
end
