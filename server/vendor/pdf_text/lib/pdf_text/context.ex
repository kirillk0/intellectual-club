defmodule PdfText.Context do
  @moduledoc false
  @key {__MODULE__, :context}
  @block_bytes 8192
  @defaults %{
    tokens: 2_000_000,
    objects: 100_000,
    xref_entries: 250_000,
    revisions: 64,
    depth: 64,
    token_bytes: 65_536,
    collection: 20_000,
    stream_bytes: 8_388_608,
    decoded_bytes: 67_108_864,
    operations: 1_000_000,
    pages: 10_000,
    page_nodes: 100_000,
    forms: 10_000,
    form_depth: 24,
    glyphs: 2_000_000,
    cmap_entries: 100_000,
    cmap_work: 2_000_000,
    cmap_bytes: 1_048_576,
    cache_entries: 128,
    cache_bytes: 4_194_304,
    predictor_row: 65_536
  }
  def defaults, do: @defaults

  def run(opts, fun) do
    old = List.keyfind(Process.get(), @key, 0)

    try do
      Process.put(
        @key,
        Map.merge(
          %{
            limits: opts.limits,
            counts: %{},
            deadline: System.monotonic_time(:millisecond) + opts.timeout_ms,
            warnings: [],
            partial: false,
            truncated: false,
            chunks: [],
            pending_chunks: [],
            pending_bytes: 0,
            chars: 0,
            output_bytes: 0,
            max_chars: opts.max_chars,
            max_output_bytes: opts.max_output_bytes,
            page_count: 0,
            pages_extracted: 0,
            cache: %{},
            cache_size: 0,
            fonts: %{},
            font_cache_size: 0,
            resolving: MapSet.new()
          },
          %{}
        )
      )

      fun.()
    after
      case old do
        nil -> Process.delete(@key)
        {_, value} -> Process.put(@key, value)
      end
    end
  end

  # Expose the pending tail without finalizing it, so reads cannot fragment the buffer.
  def get(:chunks) do
    state = Process.get(@key)

    case state.pending_chunks do
      [] -> state.chunks
      pending -> [pending |> Enum.reverse() |> IO.iodata_to_binary() | state.chunks]
    end
  end

  def get(k), do: Map.fetch!(Process.get(@key), k)
  def put(k, v), do: Process.put(@key, Map.put(Process.get(@key), k, v))
  def limit(k), do: Map.fetch!(get(:limits), k)

  def check do
    if System.monotonic_time(:millisecond) >= get(:deadline), do: throw({:pdf_limit, :timeout})
  end

  def bound(k, n) when is_integer(n) and n >= 0 do
    check()
    if n > limit(k), do: throw({:pdf_limit, k})
    n
  end

  def bound(_, _), do: fail(:invalid_pdf)

  def tick(k, n \\ 1) do
    counts = get(:counts)
    value = Map.get(counts, k, 0) + n
    bound(k, value)
    put(:counts, Map.put(counts, k, value))
  end

  def fail(reason), do: throw({:pdf_error, reason})

  def warn(reason) do
    reason =
      case reason do
        {:limit, key} -> %{reason: :limit, limit: key}
        atom when is_atom(atom) -> %{reason: atom}
      end

    put(:partial, true)
    warnings = get(:warnings)
    if length(warnings) < 32 and reason not in warnings, do: put(:warnings, [reason | warnings])
  end

  def output(text) when is_binary(text) do
    check()
    append(text, [], 0, 0)
  end

  defp append(<<>>, acc, chars, bytes), do: flush(acc, chars, bytes)

  defp append(text, acc, chars, bytes) when bytes >= @block_bytes - 3 do
    flush(acc, chars, bytes)
    append(text, [], 0, 0)
  end

  defp append(<<c::utf8, rest::binary>>, acc, chars, bytes) do
    b = <<c::utf8>>

    if get(:chars) + chars + 1 > get(:max_chars) or
         get(:output_bytes) + bytes + byte_size(b) > get(:max_output_bytes) do
      flush(acc, chars, bytes)
      throw(:pdf_output_limit)
    end

    append(rest, [b | acc], chars + 1, bytes + byte_size(b))
  end

  defp flush([], _, _), do: :ok

  defp flush(acc, chars, bytes) do
    state = Process.get(@key)
    pending = [acc |> Enum.reverse() |> IO.iodata_to_binary() | state.pending_chunks]
    pending_bytes = state.pending_bytes + bytes

    {chunks, pending, pending_bytes} =
      if pending_bytes >= @block_bytes do
        block = pending |> Enum.reverse() |> IO.iodata_to_binary()
        {[block | state.chunks], [], 0}
      else
        {state.chunks, pending, pending_bytes}
      end

    Process.put(@key, %{
      state
      | chunks: chunks,
        pending_chunks: pending,
        pending_bytes: pending_bytes,
        chars: state.chars + chars,
        output_bytes: state.output_bytes + bytes
    })

    :ok
  end
end
