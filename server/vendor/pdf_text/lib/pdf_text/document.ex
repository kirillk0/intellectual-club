defmodule PdfText.Document do
  @moduledoc false
  alias PdfText.{Parser, Codec}
  alias PdfText.Context, as: C

  def open(bytes) do
    C.put(:source, bytes)
    C.put(:xref, %{})
    size = byte_size(bytes)
    tail = binary_part(bytes, max(0, size - 4096), min(size, 4096))
    matches = :binary.matches(tail, "startxref")
    if matches == [], do: C.fail(:missing_xref)
    {pos, _} = List.last(matches)
    {offset, _} = Parser.value(binary_part(tail, pos + 9, byte_size(tail) - pos - 9), 0, false)
    {xref, trailer} = revisions(offset, %{}, %{}, MapSet.new())
    C.put(:xref, xref)
    catalog = resolve(trailer["Root"])
    if not is_map(catalog), do: C.fail(:invalid_catalog)
    pages = pages(catalog["Pages"], nil, MapSet.new(), 0, []) |> Enum.reverse()
    C.put(:page_count, length(pages))
    clear_cache()
    pages
  end

  defp revisions(nil, xref, trailer, _), do: {xref, trailer}

  defp revisions(offset, xref, trailer, seen) do
    C.tick(:revisions)
    if MapSet.member?(seen, offset), do: C.fail(:xref_cycle)
    seen = MapSet.put(seen, offset)
    {entries, dict} = section(offset)
    encrypted!(dict)
    # Hybrid stream entries override the table in the same revision; newer
    # revisions (including free entries) always override older revisions.
    {entries, seen} =
      case dict["XRefStm"] do
        nil ->
          {entries, seen}

        hybrid ->
          C.tick(:revisions)
          if MapSet.member?(seen, hybrid), do: C.fail(:xref_cycle)
          {extra, hd} = section(hybrid)
          encrypted!(hd)
          {Map.merge(entries, extra), MapSet.put(seen, hybrid)}
      end

    xref = Map.merge(entries, xref)
    C.put(:xref, xref)
    revisions(dict["Prev"], xref, Map.merge(dict, trailer), seen)
  end

  defp encrypted!(dict) do
    if Map.has_key?(dict, "Encrypt") and dict["Encrypt"] != nil, do: C.fail(:encrypted_pdf)
  end

  defp section(offset) do
    case at(offset) |> Parser.skip() do
      <<"xref", rest::binary>> ->
        table(rest, %{})

      _ ->
        {_id, _gen, object} = indirect(offset)

        case object do
          {:stream, dict, bytes} ->
            if dict["Type"] != {:name, "XRef"}, do: C.fail(:invalid_xref)
            encrypted!(dict)
            {stream_entries(Codec.decode(bytes, dict), dict), dict}

          _ ->
            C.fail(:invalid_xref)
        end
    end
  end

  defp table(data, entries) do
    case Parser.skip(data) do
      <<"trailer", rest::binary>> ->
        {dict, _} = Parser.value(rest)
        if not is_map(dict), do: C.fail(:invalid_xref)
        {entries, dict}

      rest ->
        {start, rest} = Parser.value(rest, 0, false)
        {count, rest} = Parser.value(rest, 0, false)
        nonnegative!(start)
        nonnegative!(count)
        C.tick(:xref_entries, count)
        {entries, rest} = table_rows(rest, start, count, entries)
        table(rest, entries)
    end
  end

  defp table_rows(rest, _, 0, entries), do: {entries, rest}

  defp table_rows(data, id, count, entries) do
    {offset, rest} = Parser.value(data, 0, false)
    {gen, rest} = Parser.value(rest, 0, false)
    {kind, rest} = Parser.value(rest, 0, false)
    nonnegative!(offset)
    nonnegative!(gen)

    entry =
      case kind do
        {:kw, "n"} -> {:offset, offset, gen}
        {:kw, "f"} -> :free
        _ -> C.fail(:invalid_xref)
      end

    table_rows(rest, id + 1, count - 1, Map.put(entries, id, entry))
  end

  defp stream_entries(bytes, dict) do
    widths = dict["W"]

    if not (is_list(widths) and length(widths) == 3 and
              Enum.all?(widths, &(is_integer(&1) and &1 in 0..8))),
       do: C.fail(:invalid_xref)

    [a, b, c] = widths
    if a + b + c == 0, do: C.fail(:invalid_xref)
    size = dict["Size"]
    nonnegative!(size)
    index = Map.get(dict, "Index", [0, size])
    if not is_list(index) or rem(length(index), 2) != 0, do: C.fail(:invalid_xref)

    {entries, _} =
      Enum.chunk_every(index, 2)
      |> Enum.reduce({%{}, bytes}, fn [start, count], {acc, rest} ->
        nonnegative!(start)
        nonnegative!(count)
        C.tick(:xref_entries, count)
        stream_rows(rest, start, count, {a, b, c}, acc)
      end)

    entries
  end

  defp stream_rows(rest, _, 0, _, entries), do: {entries, rest}

  defp stream_rows(data, id, count, {a, b, c} = w, entries) do
    C.check()

    case data do
      <<t::unsigned-big-integer-size(^a * 8), f2::unsigned-big-integer-size(^b * 8),
        f3::unsigned-big-integer-size(^c * 8), rest::binary>> ->
        t = if a == 0, do: 1, else: t

        entry =
          case t do
            0 -> :free
            1 -> {:offset, f2, f3}
            2 -> {:compressed, f2, f3}
            _ -> :free
          end

        stream_rows(rest, id + 1, count - 1, w, Map.put(entries, id, entry))

      _ ->
        C.fail(:invalid_xref)
    end
  end

  def resolve({:ref, id, gen} = ref) do
    C.check()

    case Map.fetch(C.get(:cache), ref) do
      {:ok, object} ->
        object

      :error ->
        seen = C.get(:resolving)
        if MapSet.member?(seen, ref), do: C.fail(:object_cycle)
        C.bound(:depth, MapSet.size(seen) + 1)
        C.tick(:objects)
        C.put(:resolving, MapSet.put(seen, ref))

        try do
          object =
            case Map.get(C.get(:xref), id) do
              {:offset, offset, ^gen} ->
                case indirect(offset) do
                  {^id, ^gen, object} -> object
                  _ -> C.fail(:invalid_object)
                end

              {:compressed, stream, index} when gen == 0 ->
                compressed_object(stream, index, id)

              _ ->
                C.fail(:missing_object)
            end

          cache(ref, object)
          object
        after
          C.put(:resolving, seen)
        end
    end
  end

  def resolve(object), do: object
  def deref(value, depth \\ 0)

  def deref({:ref, _, _} = ref, depth) do
    C.bound(:depth, depth)
    deref(resolve(ref), depth + 1)
  end

  def deref(value, _), do: value

  defp indirect(offset) do
    {id, rest} = Parser.value(at(offset), 0, false)
    {gen, rest} = Parser.value(rest, 0, false)
    {{:kw, "obj"}, rest} = Parser.value(rest, 0, false)
    nonnegative!(id)
    nonnegative!(gen)
    {object, rest} = Parser.value(rest)

    case Parser.skip(rest) do
      <<"stream", tail::binary>> when is_map(object) ->
        tail =
          case tail do
            <<13, 10, r::binary>> -> r
            <<c, r::binary>> when c in [10, 13] -> r
            _ -> C.fail(:invalid_stream)
          end

        len = deref(object["Length"])
        nonnegative!(len)
        if len > byte_size(tail), do: C.fail(:invalid_stream_length)
        <<bytes::binary-size(^len), after_stream::binary>> = tail

        case Parser.skip(after_stream) do
          <<"endstream", rest::binary>> ->
            {{:kw, "endobj"}, _} = Parser.value(rest, 0, false)
            {id, gen, {:stream, object, bytes}}

          _ ->
            C.fail(:invalid_stream_length)
        end

      rest ->
        {{:kw, "endobj"}, _} = Parser.value(rest, 0, false)
        {id, gen, object}
    end
  end

  defp compressed_object(stream, index, id) do
    nonnegative!(index)
    key = {:objstm, stream}

    {bytes, first, headers} =
      case Map.fetch(C.get(:cache), key) do
        {:ok, v} ->
          v

        :error ->
          case resolve({:ref, stream, 0}) do
            {:stream, dict, raw} ->
              if dict["Type"] != {:name, "ObjStm"}, do: C.fail(:invalid_object_stream)
              n = dict["N"]
              first = dict["First"]
              nonnegative!(n)
              nonnegative!(first)
              C.bound(:collection, n)
              bytes = Codec.decode(raw, dict)
              if first > byte_size(bytes), do: C.fail(:invalid_object_stream)
              {headers, remainder} = headers(binary_part(bytes, 0, first), n, [])
              if Parser.skip(remainder) != <<>>, do: C.fail(:invalid_object_stream)
              v = {bytes, first, List.to_tuple(headers)}
              cache(key, v)
              v

            _ ->
              C.fail(:invalid_object_stream)
          end
      end

    if index >= tuple_size(headers), do: C.fail(:invalid_object_stream)
    {object_id, offset} = elem(headers, index)
    if id != object_id, do: C.fail(:invalid_object_stream)
    start = first + offset

    finish =
      if index + 1 < tuple_size(headers),
        do: first + elem(elem(headers, index + 1), 1),
        else: byte_size(bytes)

    if start > finish or finish > byte_size(bytes), do: C.fail(:invalid_object_stream)
    {object, rest} = Parser.value(binary_part(bytes, start, finish - start))
    if Parser.skip(rest) != <<>>, do: C.fail(:invalid_object_stream)
    object
  end

  defp headers(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp headers(rest, n, acc) do
    {id, rest} = Parser.value(rest, 0, false)
    {offset, rest} = Parser.value(rest, 0, false)
    nonnegative!(id)
    nonnegative!(offset)
    headers(rest, n - 1, [{id, offset} | acc])
  end

  def stream(value) do
    case deref(value) do
      {:stream, dict, raw} -> Codec.decode(raw, dict)
      _ -> C.fail(:invalid_stream)
    end
  end

  def clear_cache do
    C.put(:cache, %{})
    C.put(:cache_size, 0)
  end

  defp cache(key, value) do
    size = :erlang.external_size(value)

    if size <= C.limit(:cache_bytes) do
      if map_size(C.get(:cache)) >= C.limit(:cache_entries) or
           C.get(:cache_size) + size > C.limit(:cache_bytes),
         do: clear_cache()

      C.put(:cache, Map.put(C.get(:cache), key, value))
      C.put(:cache_size, C.get(:cache_size) + size)
    end
  end

  defp pages(ref, inherited, seen, depth, acc) do
    C.tick(:page_nodes)
    C.bound(:depth, depth)
    if MapSet.member?(seen, ref), do: C.fail(:page_cycle)
    seen = MapSet.put(seen, ref)
    page = deref(ref)
    if not is_map(page), do: C.fail(:invalid_page_tree)
    resources = Map.get(page, "Resources", inherited)

    case page["Type"] do
      {:name, "Pages"} ->
        kids = deref(page["Kids"])
        if not is_list(kids), do: C.fail(:invalid_page_tree)
        Enum.reduce(kids, acc, fn kid, acc -> pages(kid, resources, seen, depth + 1, acc) end)

      {:name, "Page"} ->
        C.tick(:pages)
        [{ref, resources} | acc]

      _ ->
        C.fail(:invalid_page_tree)
    end
  end

  defp at(offset) do
    bytes = C.get(:source)

    if not is_integer(offset) or offset < 0 or offset >= byte_size(bytes),
      do: C.fail(:invalid_offset)

    binary_part(bytes, offset, byte_size(bytes) - offset)
  end

  defp nonnegative!(v) do
    if not is_integer(v) or v < 0 or v > 0x7FFFFFFFFFFFFFFF, do: C.fail(:invalid_integer)
  end
end
