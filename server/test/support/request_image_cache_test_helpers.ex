defmodule IntellectualClub.Generation.RequestImageCacheTestHelpers do
  @moduledoc false

  import ExUnit.Assertions

  @event [:intellectual_club, :generation, :request_image_cache]
  @empty_counters %{loaded_bytes: 0, miss: 0, hit: 0, encoded_bytes: 0}

  def observe_image_cache do
    tag = make_ref()
    handler = {__MODULE__, tag}

    :ok = :telemetry.attach(handler, @event, &__MODULE__.record_image_cache/4, {self(), tag})
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    tag
  end

  def image_cache_counters(tag), do: collect_counters(tag, @empty_counters)

  def assert_wire_cache(cache, payload) do
    assert is_map(cache)
    assert map_size(cache) > 0

    for {{sha256, mime, format}, entry} <- cache do
      assert is_binary(sha256)
      assert mime == entry.mime_type
      assert format in [:data_url, :base64]
      assert is_binary(entry.wire)
      assert entry.size_bytes == byte_size(payload)
      refute Map.has_key?(entry, :payload)
      refute Map.has_key?(entry, :file)
    end

    refute payload in binaries(cache)
    :ok
  end

  def record_image_cache(_event, measurements, _metadata, {pid, tag}),
    do: send(pid, {tag, measurements})

  defp collect_counters(tag, counters) do
    receive do
      {^tag, measurements} ->
        totals = Map.merge(counters, measurements, fn _key, first, second -> first + second end)
        collect_counters(tag, totals)
    after
      0 -> counters
    end
  end

  defp binaries(value) when is_binary(value), do: [value]
  defp binaries(value) when is_map(value), do: value |> Map.to_list() |> binaries()
  defp binaries(value) when is_tuple(value), do: value |> Tuple.to_list() |> binaries()
  defp binaries(value) when is_list(value), do: Enum.flat_map(value, &binaries/1)
  defp binaries(_value), do: []
end
