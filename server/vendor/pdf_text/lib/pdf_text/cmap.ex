defmodule PdfText.CMap do
  @moduledoc false
  alias PdfText.Parser, as: P
  alias PdfText.Context, as: C

  def parse(bytes) do
    C.bound(:cmap_bytes, byte_size(bytes))
    cmap = scan(bytes, nil, %{chars: %{}, ranges: [], spaces: []})

    index =
      cmap.ranges
      |> Enum.group_by(&elem(&1, 0), fn {_, a, b, value} -> {a, b, value} end)
      |> Map.new(fn {size, ranges} -> {size, PdfText.Ranges.new(ranges)} end)

    Map.put(cmap, :index, index)
  end

  defp scan(bytes, previous, cmap) do
    case P.skip(bytes) do
      <<>> ->
        cmap

      rest ->
        {token, rest} = P.value(rest, 0, false)

        case token do
          {:kw, "usecmap"} ->
            C.fail(:unsupported_cmap)

          {:kw, kind} when kind in ["beginbfchar", "beginbfrange", "begincodespacerange"] ->
            if not is_integer(previous) or previous < 0, do: C.fail(:invalid_cmap)
            C.tick(:cmap_entries, previous)
            {rest, cmap} = entries(rest, previous, kind, cmap)
            scan(rest, nil, cmap)

          _ ->
            scan(rest, token, cmap)
        end
    end
  end

  defp entries(rest, 0, kind, cmap) do
    {token, rest} = P.value(rest, 0, false)

    expected =
      case kind do
        "beginbfchar" -> "endbfchar"
        "beginbfrange" -> "endbfrange"
        "begincodespacerange" -> "endcodespacerange"
      end

    if token != {:kw, expected}, do: C.fail(:invalid_cmap)
    {rest, cmap}
  end

  defp entries(rest, n, "beginbfchar" = kind, cmap) do
    {{:str, source}, rest} = P.value(rest, 0, false)
    {{:str, dest}, rest} = P.value(rest, 0, false)
    code!(source)
    text = unicode(dest)
    entries(rest, n - 1, kind, %{cmap | chars: Map.put(cmap.chars, source, text)})
  end

  defp entries(rest, n, kind, cmap) do
    {{:str, low}, rest} = P.value(rest, 0, false)
    {{:str, high}, rest} = P.value(rest, 0, false)
    code!(low)
    code!(high)
    a = :binary.decode_unsigned(low)
    b = :binary.decode_unsigned(high)
    if byte_size(low) != byte_size(high) or b < a, do: C.fail(:invalid_cmap)
    size = byte_size(low)

    if kind == "begincodespacerange" do
      entries(rest, n - 1, kind, %{cmap | spaces: [{size, a, b} | cmap.spaces]})
    else
      {dest, rest} = P.value(rest, 0, false)

      dest =
        case dest do
          {:str, bytes} ->
            unicode(bytes)
            {:sequential, bytes}

          array when is_list(array) ->
            if length(array) != b - a + 1, do: C.fail(:invalid_cmap)
            {:array, array |> Enum.map(fn {:str, bytes} -> unicode(bytes) end) |> List.to_tuple()}

          _ ->
            C.fail(:invalid_cmap)
        end

      entries(rest, n - 1, kind, %{cmap | ranges: [{size, a, b, dest} | cmap.ranges]})
    end
  end

  defp code!(source) do
    if byte_size(source) not in 1..4, do: C.fail(:unsupported_cmap)
  end

  def unicode(bytes) do
    if byte_size(bytes) > 512 or rem(byte_size(bytes), 2) != 0, do: C.fail(:invalid_cmap)

    case :unicode.characters_to_binary(bytes, {:utf16, :big}, :utf8) do
      text when is_binary(text) -> text
      _ -> C.fail(:invalid_cmap)
    end
  end

  def lookup(cmap, code) do
    case Map.fetch(cmap.chars, code) do
      {:ok, text} ->
        text

      :error ->
        n = :binary.decode_unsigned(code)

        case Map.get(cmap.index, byte_size(code)) do
          nil ->
            nil

          ranges ->
            case PdfText.Ranges.find(ranges, n) do
              nil ->
                nil

              {low, {:array, tuple}} ->
                elem(tuple, n - low)

              {low, {:sequential, bytes}} ->
                v = :binary.decode_unsigned(bytes) + n - low
                if v >= Bitwise.bsl(1, byte_size(bytes) * 8), do: C.fail(:invalid_cmap)
                unicode(<<v::unsigned-big-integer-size(byte_size(bytes) * 8)>>)
            end
        end
    end
  end
end
