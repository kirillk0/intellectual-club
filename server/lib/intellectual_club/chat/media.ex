defmodule IntellectualClub.Chat.Media do
  @moduledoc """
  Shared helpers for persisted media contents and LLM projection.
  """

  alias IntellectualClub.Generation.NativeModalities

  @type media_descriptor :: %{
          required(:external_id) => String.t(),
          required(:file_external_id) => String.t(),
          required(:filename) => String.t(),
          required(:mime_type) => String.t(),
          required(:size_bytes) => non_neg_integer(),
          required(:sha256) => String.t(),
          required(:is_image) => boolean(),
          optional(:file_id) => integer() | nil
        }

  @spec media_descriptor(map()) :: media_descriptor() | nil
  def media_descriptor(content) when is_map(content) do
    if media_content?(content) do
      file = file_for_content(content)
      external_id = Map.get(content, :external_id)
      file_external_id = Map.get(file, :external_id)
      filename = Map.get(file, :filename) || Map.get(content, :filename)

      mime_type =
        Map.get(file, :mime_type) || Map.get(content, :mime_type)

      sha256 = Map.get(file, :sha256) || Map.get(content, :sha256)

      size_bytes =
        Map.get(file, :size_bytes) || Map.get(content, :size_bytes)

      file_id = Map.get(content, :file_id) || Map.get(file, :id)

      if blank?(external_id) or blank?(file_external_id) or blank?(filename) or
           blank?(mime_type) or blank?(sha256) do
        nil
      else
        %{
          external_id: to_string(external_id),
          file_external_id: to_string(file_external_id),
          filename: to_string(filename),
          mime_type: to_string(mime_type),
          size_bytes: normalize_size_bytes(size_bytes),
          sha256: to_string(sha256),
          is_image: image_mime_type?(mime_type),
          file_id: normalize_integer(file_id)
        }
      end
    else
      nil
    end
  end

  def media_descriptor(_other), do: nil

  @spec placeholder_text(map()) :: String.t()
  def placeholder_text(content) when is_map(content) do
    case media_descriptor(content) do
      %{} = media ->
        [
          "[Attached file",
          "file_id=#{media.file_external_id}",
          "filename=#{inspect(media.filename)}",
          "mime_type=#{inspect(media.mime_type)}",
          "size_bytes=#{media.size_bytes}]"
        ]
        |> Enum.join(" ")

      nil ->
        "[Attached file]"
    end
  end

  def placeholder_text(_other), do: "[Attached file]"

  @spec chat_message_content(list(), keyword()) :: String.t() | list(map())
  def chat_message_content(contents, opts \\ [])

  def chat_message_content(contents, opts) when is_list(contents) and is_list(opts) do
    supports_image_input = Keyword.get(opts, :supports_image_input, false)

    blocks =
      contents
      |> Enum.filter(&is_map/1)
      |> Enum.sort_by(&sort_seq/1)
      |> Enum.flat_map(fn content ->
        case Map.get(content, :kind) do
          :text ->
            text = Map.get(content, :content_text, "") |> to_string()
            if text == "", do: [], else: [%{"type" => "text", "text" => text}]

          :media ->
            build_chat_media_blocks(content, supports_image_input, opts)

          _other ->
            []
        end
      end)

    cond do
      blocks == [] ->
        ""

      Enum.any?(blocks, &(&1["type"] == "image_url")) ->
        blocks

      true ->
        blocks
        |> Enum.map(&Map.get(&1, "text", ""))
        |> Enum.join("")
    end
  end

  def chat_message_content(_other, _opts), do: ""

  @spec responses_message_content(list(), keyword()) :: list(map())
  def responses_message_content(contents, opts \\ [])

  def responses_message_content(contents, opts) when is_list(contents) and is_list(opts) do
    supports_image_input = Keyword.get(opts, :supports_image_input, false)
    text_type = Keyword.get(opts, :text_type, "input_text")

    contents
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn content ->
      case Map.get(content, :kind) do
        :text ->
          text = Map.get(content, :content_text, "") |> to_string()
          if text == "", do: [], else: [%{"type" => text_type, "text" => text}]

        :media ->
          build_responses_media_blocks(content, supports_image_input, text_type, opts)

        _other ->
          []
      end
    end)
  end

  def responses_message_content(_other, _opts), do: []

  @spec media_followup_messages(list(), keyword()) :: list(map())
  def media_followup_messages(contents, opts \\ []) when is_list(contents) and is_list(opts) do
    contents
    |> Enum.filter(&media_content?/1)
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.map(fn content ->
      %{"role" => "user", "content" => chat_message_content([content], opts)}
    end)
    |> Enum.reject(fn message ->
      case Map.get(message, "content") do
        "" -> true
        [] -> true
        _ -> false
      end
    end)
  end

  @spec media_followup_input_items(list(), keyword()) :: list(map())
  def media_followup_input_items(contents, opts \\ []) when is_list(contents) and is_list(opts) do
    contents
    |> Enum.filter(&media_content?/1)
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.map(fn content ->
      %{
        "type" => "message",
        "role" => "user",
        "content" => responses_message_content([content], opts)
      }
    end)
    |> Enum.reject(fn item ->
      case Map.get(item, "content") do
        [] -> true
        _ -> false
      end
    end)
  end

  @spec image_mime_type?(String.t() | nil) :: boolean()
  def image_mime_type?(mime_type) when is_binary(mime_type) do
    String.starts_with?(String.downcase(String.trim(mime_type)), "image/")
  end

  def image_mime_type?(_mime_type), do: false

  @spec media_content?(map()) :: boolean()
  def media_content?(content) when is_map(content) do
    Map.get(content, :kind) == :media
  end

  def media_content?(_other), do: false

  defp build_chat_media_blocks(content, supports_image_input, opts)
       when is_list(opts) do
    placeholder = %{"type" => "text", "text" => placeholder_text(content)}

    case maybe_native_image_block(content, supports_image_input, opts) do
      :skip -> [placeholder]
      {:fallback, text} -> [placeholder, %{"type" => "text", "text" => "\n" <> text}]
      {:ok, image_block} -> [placeholder, image_block]
    end
  end

  defp build_responses_media_blocks(content, supports_image_input, text_type, opts)
       when is_list(opts) do
    placeholder = %{"type" => text_type, "text" => placeholder_text(content)}

    case maybe_native_responses_image_block(content, supports_image_input, text_type, opts) do
      :skip -> [placeholder]
      {:fallback, text} -> [placeholder, %{"type" => text_type, "text" => text}]
      {:ok, image_block} -> [placeholder, image_block]
    end
  end

  defp maybe_native_image_block(content, true, opts) when is_list(opts) do
    case NativeModalities.project_media_content(content, opts) do
      {:ok, %{modality: :image, data_url: data_url}} ->
        {:ok, %{"type" => "image_url", "image_url" => %{"url" => data_url}}}

      {:error, text} when is_binary(text) ->
        {:fallback, text}

      _other ->
        :skip
    end
  end

  defp maybe_native_image_block(_content, _supports_image_input, _opts), do: :skip

  defp maybe_native_responses_image_block(content, true, "input_text", opts) when is_list(opts) do
    case NativeModalities.project_media_content(content, opts) do
      {:ok, %{modality: :image, data_url: data_url}} ->
        {:ok, %{"type" => "input_image", "image_url" => data_url}}

      {:error, text} when is_binary(text) ->
        {:fallback, text}

      _other ->
        :skip
    end
  end

  defp maybe_native_responses_image_block(_content, _supports_image_input, _text_type, _opts),
    do: :skip

  defp file_for_content(content) do
    case Map.get(content, :file) do
      %Ash.NotLoaded{} -> %{}
      %{} = file -> file
      _other -> %{}
    end
  end

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp blank?(value), do: to_string(value || "") |> String.trim() == ""

  defp normalize_integer(value) when is_integer(value), do: value
  defp normalize_integer(_other), do: nil

  defp normalize_size_bytes(value) when is_integer(value) and value >= 0, do: value
  defp normalize_size_bytes(_other), do: 0
end
