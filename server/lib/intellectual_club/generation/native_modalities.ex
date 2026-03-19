defmodule IntellectualClub.Generation.NativeModalities do
  @moduledoc """
  Validates canonical media contents before projecting them into provider-native modalities.
  """

  require Logger

  alias IntellectualClub.Files

  @invalid_image_fallback "[Image omitted: attached file could not be validated as an image.]"

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
         {:ok, {_file, payload}} <- Files.load_payload(file_id),
         {mime_type, _width, _height, _variant} <- ExImageInfo.info(payload) do
      {:ok,
       %{
         modality: :image,
         mime_type: mime_type,
         data_url: "data:#{mime_type};base64," <> Base.encode64(payload)
       }}
    else
      _other ->
        log_invalid_image(candidate, opts)
        {:error, @invalid_image_fallback}
    end
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
