defmodule IntellectualClub.Generation.RequestImages.Cache do
  @moduledoc """
  Worker-owned, content-addressed wire image cache. Entries contain verified
  metadata and the final wire binary, never raw payloads or file ownership.
  A hit does not grant access: callers must first resolve a step-local binding.
  """

  @event [:intellectual_club, :generation, :request_image_cache]

  def key(sha256, mime_type, format_key), do: {sha256, mime_type, format_key}

  def fetch(cache, file, descriptor) do
    key = key(file.sha256, descriptor.mime_type, descriptor.format_key)

    case Map.fetch(cache, key) do
      {:ok, %{size_bytes: size} = image} when size == file.size_bytes ->
        :telemetry.execute(@event, %{hit: 1}, %{})
        {:ok, Map.put(image, :file, file)}

      _ ->
        :error
    end
  end

  def put(cache, image, descriptor) do
    key = key(image.file.sha256, image.mime_type, descriptor.format_key)

    case Map.fetch(cache, key) do
      {:ok, cached} ->
        {cached, cache}

      :error ->
        encoded = descriptor.format.(Base.encode64(image.payload), image.mime_type)
        true = is_binary(encoded)

        cached = %{
          wire: encoded,
          mime_type: image.mime_type,
          width: image.width,
          height: image.height,
          size_bytes: image.file.size_bytes
        }

        :telemetry.execute(@event, %{encoded_bytes: byte_size(encoded), miss: 1}, %{})
        {cached, Map.put(cache, key, cached)}
    end
  end

  def retain(cache, keys), do: Map.take(cache, Enum.uniq(keys))
end
