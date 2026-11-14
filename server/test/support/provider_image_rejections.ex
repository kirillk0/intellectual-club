defmodule IntellectualClub.TestSupport.ProviderImageRejections do
  @moduledoc """
  Provider error metadata, as adapters emit it in `{:response_error, meta}`, for
  tests of the reaction to providers rejecting a request image.

  `rejections/0` are real rejections of one image (`{name, meta}`); `unrelated/0`
  are errors that must keep their ordinary handling.
  """

  @doc "Errors with which providers rejected a request image."
  def rejections do
    chatgpt =
      for {name, message} <- [
            {"an undecodable JPEG",
             ~s(input_image image_url could not parse image: Format error decoding Jpeg: ) <>
               ~s("Encountered Huffman table with excessive length in DHT")},
            {"an unknown format", "input_image image_url unsupported image format: unknown"},
            {"a decoder memory limit",
             "input_image image_url could not parse image: Memory limit exceeded"},
            {"a truncated WebP",
             "input_image image_url could not parse image: Invalid or truncated WebP container"}
          ] do
        {"ChatGPT backend rejecting #{name}", chatgpt_backend(message)}
      end

    chatgpt ++
      [
        {"OpenAI API rejecting invalid image data",
         http(
           "The image data you provided does not represent a valid image. " <>
             "Please check your input and try again.",
           %{"code" => "invalid_value", "param" => "input", "type" => "invalid_request_error"}
         )},
        {"Google Interactions failing to process an image",
         http(
           "Unable to process input image. Please retry or report in " <>
             "https://developers.generativeai.google/guide/troubleshooting",
           %{"code" => "invalid_request"}
         )},
        {"OpenRouter relaying an Anthropic processing failure",
         openrouter(
           ~s({"type":"error","error":{"type":"invalid_request_error",) <>
             ~s("message":"Could not process image"},"request_id":"req_011CTestImageRejection"})
         )},
        {"OpenRouter relaying an Anthropic media type validation",
         openrouter(
           "messages.0.content.1.image.source.base64.media_type: Input should be " <>
             "'image/jpeg', 'image/png', 'image/gif' or 'image/webp'"
         )},
        {"Anthropic rejecting a mislabeled media type",
         anthropic(
           "messages.0.content.1.image.source.base64: The image was specified using the " <>
             "image/jpeg media type, but the image appears to be a image/png image"
         )},
        {"Anthropic rejecting an image over 10 MB",
         anthropic(
           "messages.12.content.0.tool_result.content.2.image.source.base64: image exceeds " <>
             "10 MB maximum: 14501068 bytes > 10485760 bytes"
         )}
      ]
  end

  @doc "Errors that mention images or are invalid requests, but do not reject one image."
  def unrelated do
    [
      {"a model without image input",
       http("This model does not support image input.", %{"type" => "invalid_request_error"})},
      {"image input disabled for the model",
       anthropic("messages.0.content.1.image: image input is not supported for this model")},
      {"OpenRouter without image endpoints",
       Map.put(openrouter("No endpoints found that support image input"), :status_code, 404)},
      {"an exceeded context window",
       http(
         "This model's maximum context length is 128000 tokens. However, your messages " <>
           "resulted in 131072 tokens (including 1105 in your image inputs).",
         %{"code" => "context_length_exceeded", "type" => "invalid_request_error"}
       )},
      {"a too long Anthropic prompt",
       anthropic("prompt is too long: 215000 tokens > 200000 maximum")},
      {"another invalid request",
       http("Invalid value for 'temperature': expected a number between 0 and 2.", %{
         "type" => "invalid_request_error"
       })},
      {"an authentication failure", %{http("Could not process image", %{}) | status_code: 401}},
      {"a forbidden request", %{http("Could not process image", %{}) | status_code: 403}},
      {"a server error", %{http("Unable to process input image", %{}) | status_code: 500}},
      {"an in-stream error without invalid_request",
       %{
         status_code: nil,
         retryable: false,
         error_kind: "provider",
         error_text: "input_image image_url could not parse image: Memory limit exceeded",
         raw_response: %{"type" => "error", "error" => %{"type" => "server_error"}}
       }}
    ]
  end

  defp chatgpt_backend(message) do
    %{
      status_code: nil,
      retryable: false,
      error_kind: "provider",
      error_text: message,
      raw_response: %{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "code" => nil,
          "param" => nil,
          "message" => message
        }
      }
    }
  end

  defp http(message, error) do
    %{
      status_code: 400,
      retryable: false,
      error_kind: "http",
      error_text: message,
      raw_response: %{"error" => Map.put(error, "message", message)}
    }
  end

  defp openrouter(raw) do
    %{
      status_code: 400,
      retryable: false,
      error_kind: "http",
      error_text: raw,
      raw_response: %{
        "error" => %{
          "code" => 400,
          "message" => "Provider returned error",
          "metadata" => %{"raw" => raw, "provider_name" => "Anthropic"}
        }
      }
    }
  end

  defp anthropic(message) do
    %{
      status_code: 400,
      retryable: false,
      error_kind: "http",
      error_text: message,
      raw_response: %{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => message}
      }
    }
  end
end
