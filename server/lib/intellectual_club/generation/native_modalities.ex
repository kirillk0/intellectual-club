defmodule IntellectualClub.Generation.NativeModalities do
  @moduledoc """
  Validates canonical media contents before projecting them into provider-native modalities.
  """

  require Logger

  alias IntellectualClub.Files

  @max_native_image_edge_px 2_000
  @invalid_image_fallback "[Image omitted: attached file could not be validated as an image.]"
  @oversized_image_fallback "[Image omitted: attached image exceeded the native image size limit and could not be resized.]"

  @type projection :: %{
          modality: :image,
          mime_type: String.t(),
          data_url: String.t()
        }

  @spec project_media_content(map(), keyword()) ::
          {:ok, projection()} | {:error, String.t()} | :skip
  def project_media_content(content, opts \\ [])

  def project_media_content(content, opts) when is_map(content) and is_list(opts) do
    case image_candidate(content) do
      nil ->
        :skip

      candidate ->
        project_image_candidate(candidate, opts)
    end
  end

  def project_media_content(_other, _opts), do: :skip

  defp project_image_candidate(candidate, opts) do
    with file_id when is_integer(file_id) <- candidate.file_id,
         {:ok, {_file, payload}} <- Files.load_payload(file_id) do
      case ExImageInfo.info(payload) do
        {mime_type, width, height, _variant}
        when is_integer(width) and is_integer(height) and width > 0 and height > 0 ->
          case normalize_image_payload(payload, mime_type, width, height, candidate, opts) do
            {:ok, normalized_payload, normalized_mime_type} ->
              {:ok,
               %{
                 modality: :image,
                 mime_type: normalized_mime_type,
                 data_url:
                   "data:#{normalized_mime_type};base64," <> Base.encode64(normalized_payload)
               }}

            {:error, fallback} when is_binary(fallback) ->
              {:error, fallback}
          end

        _other ->
          log_invalid_image(candidate, opts)
          {:error, @invalid_image_fallback}
      end
    else
      _other ->
        log_invalid_image(candidate, opts)
        {:error, @invalid_image_fallback}
    end
  end

  defp normalize_image_payload(payload, mime_type, width, height, candidate, opts) do
    if max(width, height) <= @max_native_image_edge_px do
      {:ok, payload, mime_type}
    else
      case resize_image_payload(payload, mime_type) do
        {:ok, resized_payload, resized_mime_type} ->
          {:ok, resized_payload, resized_mime_type}

        {:error, reason} ->
          log_resize_failure(candidate, opts, reason, mime_type, width, height)
          {:error, @oversized_image_fallback}
      end
    end
  end

  defp resize_image_payload(payload, mime_type)
       when is_binary(payload) and is_binary(mime_type) do
    try do
      with {:ok, suffix} <- image_suffix(mime_type),
           {:ok, image} <- Image.from_binary(payload),
           {:ok, resized_image} <-
             Image.thumbnail(image, @max_native_image_edge_px, resize: :down),
           {:ok, resized_payload} when is_binary(resized_payload) <-
             Image.write(resized_image, :memory, suffix: suffix),
           {resized_mime_type, resized_width, resized_height, _variant}
           when is_integer(resized_width) and is_integer(resized_height) <-
             ExImageInfo.info(resized_payload),
           true <- max(resized_width, resized_height) <= @max_native_image_edge_px do
        {:ok, resized_payload, resized_mime_type}
      else
        false -> {:error, :resized_image_exceeds_limit}
        nil -> {:error, :resized_image_invalid}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, value -> {:error, {kind, value}}
    end
  end

  defp resize_image_payload(_payload, _mime_type), do: {:error, :invalid_resize_payload}

  defp image_suffix(mime_type) when is_binary(mime_type) do
    case normalize_mime_type(mime_type) do
      "image/png" -> {:ok, ".png"}
      "image/jpeg" -> {:ok, ".jpg"}
      "image/jpg" -> {:ok, ".jpg"}
      "image/webp" -> {:ok, ".webp"}
      "image/gif" -> {:ok, ".gif"}
      "image/tiff" -> {:ok, ".tif"}
      "image/x-tiff" -> {:ok, ".tif"}
      "image/avif" -> {:ok, ".avif"}
      "image/heif" -> {:ok, ".heif"}
      "image/heic" -> {:ok, ".heif"}
      normalized -> {:error, {:unsupported_image_mime_type, normalized}}
    end
  end

  defp normalize_mime_type(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp image_candidate(content) do
    file = file_for_content(content)

    mime_type =
      map_get(file, :mime_type, "mime_type") || map_get(content, :mime_type, "mime_type")

    if image_mime_type?(mime_type) do
      %{
        file_id:
          normalize_integer(map_get(content, :file_id, "file_id") || map_get(file, :id, "id")),
        filename: map_get(file, :filename, "filename") || map_get(content, :filename, "filename"),
        sha256: map_get(file, :sha256, "sha256") || map_get(content, :sha256, "sha256"),
        declared_mime_type: to_string(mime_type)
      }
    else
      nil
    end
  end

  defp log_invalid_image(candidate, opts) do
    provider_type = Keyword.get(opts, :provider_type)

    Logger.warning(
      "Skipping invalid native image projection file_id=#{inspect(candidate.file_id)} " <>
        "filename=#{inspect(candidate.filename)} sha256=#{inspect(candidate.sha256)} " <>
        "declared_mime_type=#{inspect(candidate.declared_mime_type)} " <>
        "provider_type=#{inspect(provider_type)}"
    )
  end

  defp log_resize_failure(candidate, opts, reason, mime_type, width, height) do
    provider_type = Keyword.get(opts, :provider_type)

    Logger.warning(
      "Skipping oversized native image projection file_id=#{inspect(candidate.file_id)} " <>
        "filename=#{inspect(candidate.filename)} sha256=#{inspect(candidate.sha256)} " <>
        "mime_type=#{inspect(mime_type)} width=#{inspect(width)} height=#{inspect(height)} " <>
        "max_edge_px=#{@max_native_image_edge_px} reason=#{inspect(reason)} " <>
        "provider_type=#{inspect(provider_type)}"
    )
  end

  defp image_mime_type?(mime_type) when is_binary(mime_type) do
    String.starts_with?(String.downcase(String.trim(mime_type)), "image/")
  end

  defp image_mime_type?(_mime_type), do: false

  defp file_for_content(content) do
    case map_get(content, :file, "file") do
      %Ash.NotLoaded{} -> %{}
      %{} = file -> file
      _other -> %{}
    end
  end

  defp map_get(map, atom_key, string_key, default \\ nil) when is_map(map) do
    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_other), do: nil
end
