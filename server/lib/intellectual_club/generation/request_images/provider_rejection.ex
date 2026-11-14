defmodule IntellectualClub.Generation.RequestImages.ProviderRejection do
  @moduledoc """
  Recognizes provider errors that reject a request image and selects the images
  to blame for them.

  The predicate is provider-independent. It requires an invalid-request status,
  that is HTTP 400, or no status on a `"provider"` error whose body carries an
  `invalid_request` type or code (as the ChatGPT backend reports in-stream), and
  an error text about processing, the format or the size of an image. Errors
  saying that the model does not accept images at all, context-limit errors and
  any other status never match: replacing images with text cannot fix them.

  Suspects are chosen among the images the failed attempt actually sent (`S`,
  as reported by hydration): those the configuration has not accepted before
  (`S'`), or all of `S` when it accepted every one of them.
  """

  @max_depth 6
  @max_list_items 20
  @max_text_length 2_000
  @max_summary_length 300

  # Checked first: these texts may mention images but are not about one image.
  @unrelated_patterns [
    ~r/\b(?:does not|doesn't|do not|don't|cannot|can't) (?:support|accept|handle) (?:images?|vision|multimodal)/i,
    ~r/\bimages? (?:inputs? )?(?:is |are )?not (?:supported|enabled|allowed|available)/i,
    ~r/\bunsupported image input/i,
    ~r/\bsupports? image input/i,
    ~r/\bvision (?:is )?not supported/i,
    ~r/\bcontext (?:length|window)/i,
    ~r/\bmaximum context/i,
    ~r/\btoo many (?:input )?tokens/i,
    ~r/\bprompt is too long/i
  ]

  @image_patterns [
    # "could not parse image", "Could not process image", "Unable to process input image"
    ~r/\b(?:could not|couldn't|unable to|failed to|cannot|can't) (?:parse|process|decode|read|load|open) (?:the |this |an |your )?(?:input |provided |uploaded |attached )?image\b/i,
    # "unsupported image format: unknown", "You uploaded an unsupported image."
    ~r/\bunsupported image\b/i,
    ~r/\bimage (?:format|type|data|file|content) (?:is )?(?:not supported|unsupported|invalid|not valid|corrupt)/i,
    # "The image data you provided does not represent a valid image."
    ~r/\bnot (?:represent )?a valid image\b/i,
    ~r/\binvalid image (?:data|file|format|content)\b/i,
    # "... image/jpeg media type, but the image appears to be a image/png image"
    ~r/\bbut the image appears to be\b/i,
    ~r/\bdoes not match the provided media type\b/i,
    # "...image.source.base64.media_type: Input should be 'image/jpeg', ..."
    ~r/\bmedia_type: input should be '?image\//i,
    # "image exceeds 10 MB maximum", "image dimensions exceed max allowed size"
    ~r/\bimage (?:dimensions |size |file size )?exceeds?\b/i,
    ~r/\bimage (?:is )?too (?:large|big)\b/i
  ]

  @type sent_image :: %{required(:sha256) => String.t(), required(:accepted?) => boolean()}

  @doc """
  Whether provider error metadata (`:status_code`, `:error_kind`, `:error_text`,
  `:raw_response`) reports that the provider refused a request image.
  """
  @spec image_rejection?(map()) :: boolean()
  def image_rejection?(meta) when is_map(meta) do
    invalid_request?(meta) and image_problem?(error_texts(meta))
  end

  def image_rejection?(_meta), do: false

  @doc """
  The SHA-256 hashes to mark as rejected among the images an attempt sent:
  `{hashes, fallback?}`.

  Images the configuration has accepted before are trusted, so the hashes are
  those of the not yet accepted images. When every sent image was accepted
  before, the evidence contradicts the error; all of them are blamed then, so
  that the retry can still succeed, and `fallback?` is `true`. No sent images
  give `{[], false}`.
  """
  @spec suspects([sent_image()]) :: {[String.t()], boolean()}
  def suspects(sent) when is_list(sent) do
    case Enum.reject(sent, & &1.accepted?) do
      [] -> {hashes(sent), sent != []}
      unaccepted -> {hashes(unaccepted), false}
    end
  end

  defp hashes(images), do: images |> Enum.map(& &1.sha256) |> Enum.uniq() |> Enum.sort()

  @doc "A short diagnostic for the rejection fact: the provider and its error message."
  @spec details(term(), map()) :: String.t()
  def details(provider_type, meta) when is_map(meta) do
    texts = error_texts(meta)
    text = Enum.find(texts, &image_problem?([&1])) || List.first(texts) || "provider error"

    summary =
      text
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, @max_summary_length)

    "#{provider_type}: #{summary}"
  end

  defp invalid_request?(meta) do
    case Map.get(meta, :status_code) do
      400 ->
        true

      nil ->
        error_kind(meta) == "provider" and invalid_request_body?(Map.get(meta, :raw_response))

      _other ->
        false
    end
  end

  defp error_kind(meta) do
    case Map.get(meta, :error_kind) do
      kind when is_binary(kind) -> kind |> String.trim() |> String.downcase()
      _other -> ""
    end
  end

  defp invalid_request_body?(body, depth \\ @max_depth)

  defp invalid_request_body?(body, depth) when is_map(body) and depth > 0 do
    Enum.any?(body, fn
      {key, value} when key in ["type", "code", "status"] and is_binary(value) ->
        String.downcase(value) in ["invalid_request", "invalid_request_error"]

      {_key, value} ->
        invalid_request_body?(value, depth - 1)
    end)
  end

  defp invalid_request_body?(body, depth) when is_list(body) and depth > 0,
    do: body |> Enum.take(@max_list_items) |> Enum.any?(&invalid_request_body?(&1, depth - 1))

  # Bodies that are not JSON, or JSON embedded as a string (OpenRouter `metadata.raw`).
  defp invalid_request_body?(body, _depth) when is_binary(body),
    do: body |> String.slice(0, @max_text_length) |> String.contains?("invalid_request")

  defp invalid_request_body?(_body, _depth), do: false

  defp error_texts(meta) do
    [Map.get(meta, :error_text) | response_texts(Map.get(meta, :raw_response))]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.slice(&1, 0, @max_text_length))
    |> Enum.uniq()
  end

  defp response_texts(body) when is_binary(body), do: [body]
  defp response_texts(body), do: nested_texts(body, @max_depth)

  defp nested_texts(body, depth) when is_map(body) and depth > 0 do
    Enum.flat_map(body, fn
      {key, text} when key in ["message", "raw", "detail", "error"] and is_binary(text) -> [text]
      {_key, value} -> nested_texts(value, depth - 1)
    end)
  end

  defp nested_texts(body, depth) when is_list(body) and depth > 0,
    do: body |> Enum.take(@max_list_items) |> Enum.flat_map(&nested_texts(&1, depth - 1))

  defp nested_texts(_body, _depth), do: []

  defp image_problem?(texts) do
    text = Enum.join(texts, "\n")

    not Enum.any?(@unrelated_patterns, &Regex.match?(&1, text)) and
      Enum.any?(@image_patterns, &Regex.match?(&1, text))
  end
end
