defmodule PdfText.Font do
  @moduledoc false
  alias PdfText.{Document, CMap, TextEncoding}
  alias PdfText.Context, as: C

  def load(ref) do
    font = Document.deref(ref)
    if not is_map(font), do: C.fail(:unsupported_font)

    cmap =
      case font["ToUnicode"] do
        nil -> nil
        ref -> ref |> Document.stream() |> CMap.parse()
      end

    type0 = font["Subtype"] == {:name, "Type0"}

    if type0 and (font["Encoding"] != {:name, "Identity-H"} or is_nil(cmap)),
      do: C.fail(:unsupported_font)

    encoding = Document.deref(font["Encoding"])

    base =
      case encoding do
        {:name, name} ->
          name

        map when is_map(map) ->
          case map["BaseEncoding"] do
            {:name, n} -> n
            _ -> "StandardEncoding"
          end

        nil ->
          default_encoding(font)

        _ ->
          C.fail(:unsupported_font)
      end

    if not type0 and is_nil(cmap) and not TextEncoding.supported?(base),
      do: C.fail(:unsupported_font)

    diffs =
      if is_map(encoding),
        do: differences(Document.deref(encoding["Differences"]) || [], 0, %{}),
        else: %{}

    {widths, default} =
      if type0 do
        [desc | _] = Document.deref(font["DescendantFonts"])
        desc = Document.deref(desc)

        {PdfText.Ranges.new(cid_widths(Document.deref(desc["W"]) || [], [])),
         metric(Map.get(desc, "DW", 1000))}
      else
        first = Map.get(font, "FirstChar", 0)
        widths = Document.deref(font["Widths"]) || []

        if not is_integer(first) or first not in 0..255 or not is_list(widths) or
             length(widths) > 256,
           do: C.fail(:unsupported_font)

        desc = Document.deref(font["FontDescriptor"]) || %{}

        {widths |> Enum.with_index(first) |> Map.new(fn {w, i} -> {i, metric(w)} end),
         metric(Map.get(desc, "MissingWidth", 500))}
      end

    %{cmap: cmap, base: base, diffs: diffs, type0: type0, widths: widths, default: default}
  end

  defp default_encoding(font) do
    case font["BaseFont"] do
      {:name, "Symbol"} ->
        "SymbolEncoding"

      {:name, "ZapfDingbats"} ->
        "ZapfDingbatsEncoding"

      {:name, name} ->
        # Only the standard 14 fonts have a trustworthy implicit encoding.
        if name in ~w(Times-Roman Times-Bold Times-Italic Times-BoldItalic Helvetica Helvetica-Bold Helvetica-Oblique Helvetica-BoldOblique Courier Courier-Bold Courier-Oblique Courier-BoldOblique),
          do: "StandardEncoding",
          else: nil

      _ ->
        nil
    end
  end

  defp differences([], _, map), do: map

  defp differences([n | rest], _, map) when is_integer(n) and n in 0..255,
    do: differences(rest, n, map)

  defp differences([{:name, name} | rest], n, map) when n in 0..255 and byte_size(name) <= 128,
    do: differences(rest, n + 1, Map.put(map, n, name))

  defp differences(_, _, _), do: C.fail(:unsupported_font)
  defp cid_widths([], acc), do: Enum.reverse(acc)

  defp cid_widths([first, array | rest], acc)
       when is_integer(first) and first >= 0 and is_list(array) do
    C.tick(:cmap_entries, length(array))
    tuple = array |> Enum.map(&metric/1) |> List.to_tuple()
    cid_widths(rest, [{first, first + tuple_size(tuple) - 1, tuple} | acc])
  end

  defp cid_widths([first, last, w | rest], acc)
       when is_integer(first) and is_integer(last) and first >= 0 and last >= first do
    C.tick(:cmap_entries)
    cid_widths(rest, [{first, last, metric(w)} | acc])
  end

  defp cid_widths(_, _), do: C.fail(:unsupported_font)
  defp metric(n) when is_number(n) and abs(n) <= 100_000, do: n
  defp metric(_), do: C.fail(:unsupported_font)
  def chunk(font, bytes), do: glyphs(font, bytes, [], 0)
  defp glyphs(_, rest, acc, n) when rest == <<>> or n == 128, do: {Enum.reverse(acc), rest}

  defp glyphs(font, bytes, acc, count) do
    C.tick(:glyphs)
    size = if font.type0, do: 2, else: 1
    if byte_size(bytes) < size, do: C.fail(:invalid_text_string)
    <<code::binary-size(^size), rest::binary>> = bytes
    n = :binary.decode_unsigned(code)

    text =
      if font.cmap do
        CMap.lookup(font.cmap, code)
      else
        case TextEncoding.character(font.base, n, font.diffs) do
          {:ok, t} -> t
          :error -> nil
        end
      end

    if is_nil(text), do: C.warn(:unmapped_glyph)

    width =
      if font.type0 do
        case PdfText.Ranges.find(font.widths, n) do
          nil -> font.default
          {first, widths} when is_tuple(widths) -> elem(widths, n - first)
          {_, width} -> width
        end
      else
        Map.get(font.widths, n, if(n == 32, do: 250, else: font.default))
      end

    glyphs(font, rest, [{text || "", width, n == 32 and size == 1} | acc], count + 1)
  end
end
