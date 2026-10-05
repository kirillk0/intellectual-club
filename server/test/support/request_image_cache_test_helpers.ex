defmodule IntellectualClub.Generation.RequestImageCacheTestHelpers do
  @moduledoc """
  Helpers for request image tests: observing the wire cache telemetry,
  capturing the cache handed to `on_cache`, asserting cache entry shape and
  temporarily removing or corrupting a stored payload blob.
  """

  import ExUnit.Assertions

  alias IntellectualClub.Files.FilesystemStorage

  @event [:intellectual_club, :generation, :request_image_cache]
  @empty_counters %{loaded_bytes: 0, miss: 0, hit: 0, encoded_bytes: 0}

  @doc "Starts collecting request image cache telemetry; returns a tag for `image_cache_counters/1`."
  def observe_image_cache do
    tag = make_ref()
    handler = {__MODULE__, tag}

    :ok = :telemetry.attach(handler, @event, &__MODULE__.record_image_cache/4, {self(), tag})
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    tag
  end

  @doc "Sums the cache counters received since the previous call."
  def image_cache_counters(tag), do: collect_counters(tag, @empty_counters)

  @doc "Asserts that no payload was loaded, encoded or served from the cache."
  def assert_no_image_cache_work(tag), do: assert(image_cache_counters(tag) == @empty_counters)

  @doc """
  Returns `{tag, opts}`: hydration options with an empty cache whose `on_cache`
  callback sends `{tag, cache}` to the test process. `cache` replaces the
  initial cache.
  """
  def cache_probe(cache \\ %{}) do
    tag = make_ref()
    test_pid = self()
    {tag, [cache: cache, on_cache: &send(test_pid, {tag, &1})]}
  end

  @doc "Asserts that every wire cache entry is encoded and keeps no raw payload or file."
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

  @doc """
  Runs `fun.(path)` while the blob of `sha256` is absent from the filesystem
  storage, then stores `payload` again (whatever `fun` left at `path`).
  """
  def without_payload_blob(sha256, payload, fun) do
    {:ok, path} = FilesystemStorage.path_for(sha256)
    File.rm!(path)

    try do
      fun.(path)
    after
      File.rm_rf!(path)
      assert {:ok, :created} = FilesystemStorage.store(sha256, payload)
    end
  end

  @doc false
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
