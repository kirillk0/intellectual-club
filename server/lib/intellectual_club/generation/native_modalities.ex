defmodule IntellectualClub.Generation.NativeModalities do
  @moduledoc """
  Projects canonical media contents into compact provider-native modalities.

  Image bytes are deliberately not read here. Validation, optional resizing, and
  pinning happen after a request step exists in `RequestImages`.
  """

  require Logger

  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Generation.RequestImages

  @invalid_image_fallback "[Image omitted: attached file could not be validated as an image.]"

  @type projection :: %{
          modality: :image,
          mime_type: String.t(),
          data_url: map()
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
    case resolve_file(candidate) do
      {:ok, %StoredFile{} = file} ->
        mime_type = normalize_mime_type(candidate.declared_mime_type)
        encoding = Keyword.get(opts, :encoding, :data_url)

        {:ok,
         %{
           modality: :image,
           mime_type: mime_type,
           data_url: RequestImages.marker(to_string(file.external_id), mime_type, encoding)
         }}

      {:error, _reason} ->
        log_invalid_image(candidate, opts)
        {:error, @invalid_image_fallback}
    end
  end

  defp resolve_file(%{file: %StoredFile{external_id: external_id} = file})
       when not is_nil(external_id),
       do: {:ok, file}

  defp resolve_file(%{file_id: file_id}) when is_integer(file_id) do
    Ash.get(StoredFile, file_id, authorize?: false)
  end

  defp resolve_file(_candidate), do: {:error, :file_not_found}

  defp image_candidate(content) do
    file = file_for_content(content)
    mime_type = Map.get(file, :mime_type) || Map.get(content, :mime_type)

    if image_mime_type?(mime_type) do
      %{
        file: file,
        file_id: normalize_integer(Map.get(content, :file_id) || Map.get(file, :id)),
        filename: Map.get(file, :filename) || Map.get(content, :filename),
        sha256: Map.get(file, :sha256) || Map.get(content, :sha256),
        declared_mime_type: to_string(mime_type)
      }
    else
      nil
    end
  end

  defp log_invalid_image(candidate, opts) do
    Logger.warning(
      "Skipping native image projection without a canonical file " <>
        "file_id=#{inspect(candidate.file_id)} filename=#{inspect(candidate.filename)} " <>
        "sha256=#{inspect(candidate.sha256)} " <>
        "declared_mime_type=#{inspect(candidate.declared_mime_type)} " <>
        "provider_type=#{inspect(Keyword.get(opts, :provider_type))}"
    )
  end

  defp normalize_mime_type(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp image_mime_type?(mime_type) when is_binary(mime_type) do
    String.starts_with?(String.downcase(String.trim(mime_type)), "image/")
  end

  defp image_mime_type?(_mime_type), do: false

  defp file_for_content(content) do
    case Map.get(content, :file) do
      %Ash.NotLoaded{} -> %{}
      %{} = file -> file
      _other -> %{}
    end
  end

  defp normalize_integer(value) when is_integer(value), do: value
  defp normalize_integer(_other), do: nil
end
