defmodule PdfText.Content do
  @moduledoc false
  alias PdfText.{Parser, Document, Font}
  alias PdfText.Context, as: C

  @checked_operators [
    "BT",
    "ET",
    "Tf",
    "Tm",
    "Td",
    "TD",
    "T*",
    "Tc",
    "Tw",
    "Tz",
    "TL",
    "Ts",
    "Tj",
    "TJ",
    "'",
    "\"",
    "q",
    "Q",
    "Do",
    "gs"
  ]
  @identity {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}
  def page({ref, inherited}) do
    C.put(:last_text, nil)
    page = Document.deref(ref)
    resources = Document.deref(inherited) || %{}

    state = %{
      ctm: @identity,
      tm: @identity,
      line: @identity,
      font: nil,
      size: 12.0,
      char_space: 0,
      word_space: 0,
      scale: 1.0,
      leading: 0,
      rise: 0,
      stack: [],
      resources: resources
    }

    contents = Document.deref(page["Contents"])

    Enum.reduce(List.wrap(contents), {state, []}, fn content, {state, args} ->
      interpret(Document.stream(content), state, args, MapSet.new(), 0)
    end)
    |> finish()
  end

  defp interpret(bytes, state, args, seen, depth) do
    case Parser.skip(bytes) do
      <<>> ->
        {state, args}

      rest ->
        {token, rest} = Parser.value(rest, 0, false)

        case token do
          {:kw, op} ->
            C.tick(:operations)
            state = operation(op, Enum.reverse(args), state, seen, depth)
            interpret(rest, state, [], seen, depth)

          operand ->
            if length(args) >= 128, do: C.fail(:invalid_content)
            interpret(rest, state, [operand | args], seen, depth)
        end
    end
  end

  defp finish({state, []}), do: state
  defp finish(_), do: C.fail(:invalid_content)

  defp operation("ET", [], s, _, _), do: s
  defp operation("BI", _, _, _, _), do: C.fail(:unsupported_inline_image)
  defp operation("BT", [], s, _, _), do: %{s | tm: @identity, line: @identity}

  defp operation("Tf", [{:name, name}, size], s, _, _) when is_number(size) do
    numeric!(size)
    fonts = Document.deref(s.resources["Font"]) || %{}
    ref = fonts[name]

    font =
      case Map.fetch(C.get(:fonts), ref) do
        {:ok, font} ->
          font

        :error ->
          font =
            try do
              Font.load(ref)
            rescue
              _ ->
                C.warn(:unsupported_font)
                nil
            catch
              {:pdf_error, reason} ->
                C.warn(reason)
                nil
            end

          cache_font(ref, font)
          font
      end

    %{s | font: font, size: size}
  end

  defp operation("Tm", [a, b, c, d, e, f], s, _, _) do
    matrix = matrix([a, b, c, d, e, f])
    %{s | tm: matrix, line: matrix}
  end

  defp operation("Td", [x, y], s, _, _), do: move(s, x, y)
  defp operation("TD", [x, y], s, _, _), do: move(%{s | leading: -numeric!(y)}, x, y)
  defp operation("T*", [], s, _, _), do: move(s, 0, -s.leading)
  defp operation("Tc", [n], s, _, _), do: %{s | char_space: numeric!(n)}
  defp operation("Tw", [n], s, _, _), do: %{s | word_space: numeric!(n)}
  defp operation("Tz", [n], s, _, _), do: %{s | scale: numeric!(n) / 100}
  defp operation("TL", [n], s, _, _), do: %{s | leading: numeric!(n)}
  defp operation("Ts", [n], s, _, _), do: %{s | rise: numeric!(n)}
  defp operation("Tj", [{:str, bytes}], s, _, _), do: show(s, bytes)

  defp operation("TJ", [array], s, _, _) when is_list(array) do
    Enum.reduce(array, s, fn
      {:str, bytes}, s ->
        show(s, bytes)

      n, s when is_number(n) ->
        %{s | tm: translate(s.tm, -numeric!(n) / 1000 * s.size * s.scale, 0)}

      _, _ ->
        C.fail(:invalid_content)
    end)
  end

  defp operation("'", [{:str, bytes}], s, _, _), do: s |> move(0, -s.leading) |> show(bytes)

  defp operation("\"", [word, char, {:str, bytes}], s, _, _),
    do:
      %{s | word_space: numeric!(word), char_space: numeric!(char)}
      |> move(0, -s.leading)
      |> show(bytes)

  defp operation("q", [], s, _, _) do
    C.bound(:depth, length(s.stack) + 1)
    %{s | stack: [%{s | stack: []} | s.stack]}
  end

  defp operation("Q", [], %{stack: [saved | stack]} = s, _, _),
    do: %{saved | stack: stack, tm: s.tm, line: s.line}

  defp operation("Q", [], s, _, _), do: s
  defp operation("cm", args, s, _, _), do: %{s | ctm: multiply(matrix(args), s.ctm)}

  defp operation("Do", [{:name, name}], s, seen, depth) do
    xobjects = Document.deref(s.resources["XObject"]) || %{}
    ref = xobjects[name]

    case Document.deref(ref) do
      {:stream, dict, _} ->
        case dict["Subtype"] do
          {:name, "Image"} ->
            s

          {:name, "Form"} ->
            C.tick(:forms)
            C.bound(:form_depth, depth + 1)
            if MapSet.member?(seen, ref), do: C.fail(:form_cycle)
            resources = Document.deref(Map.get(dict, "Resources", s.resources))
            fm = matrix(Map.get(dict, "Matrix", [1, 0, 0, 1, 0, 0]))
            form_state = %{s | ctm: multiply(fm, s.ctm), resources: resources, stack: []}

            interpret(Document.stream(ref), form_state, [], MapSet.put(seen, ref), depth + 1)
            |> finish()

            s

          _ ->
            C.warn(:unsupported_xobject)
            s
        end

      _ ->
        C.warn(:missing_xobject)
        s
    end
  end

  defp operation("gs", [{:name, name}], s, _, _) do
    resources = Document.deref(s.resources["ExtGState"]) || %{}
    gs = Document.deref(resources[name]) || %{}

    case Document.deref(gs["Font"]) do
      [ref, size] -> %{s | font: Font.load(ref), size: numeric!(size)}
      _ -> s
    end
  end

  # Text rendering mode does not suppress an existing invisible/OCR text layer.
  # Painting paths, images, colors and clipping are intentionally not executed.
  defp operation(op, _, _, _, _) when op in @checked_operators, do: C.fail(:invalid_content)

  defp operation(_, _, s, _, _), do: s

  defp cache_font(ref, font) do
    size = :erlang.external_size({ref, font})

    if size <= C.limit(:cache_bytes) do
      cache = C.get(:fonts)

      if map_size(cache) >= min(64, C.limit(:cache_entries)) or
           C.get(:font_cache_size) + size > C.limit(:cache_bytes) do
        C.put(:fonts, %{})
        C.put(:font_cache_size, 0)
      end

      C.put(:fonts, Map.put(C.get(:fonts), ref, font))
      C.put(:font_cache_size, C.get(:font_cache_size) + size)
    end
  end

  defp show(%{font: nil} = s, _bytes) do
    C.warn(:unsupported_font)
    C.put(:last_text, nil)
    s
  end

  defp show(s, <<>>), do: s

  defp show(s, bytes) do
    {glyphs, rest} = Font.chunk(s.font, bytes)
    text = glyphs |> Enum.map(&elem(&1, 0)) |> IO.iodata_to_binary()

    advance =
      Enum.reduce(glyphs, 0, fn {_, w, space}, n ->
        n + (w / 1000 * s.size + s.char_space + if(space, do: s.word_space, else: 0)) * s.scale
      end)

    {x, y} = point(multiply(s.tm, s.ctm), 0, s.rise)
    next_tm = translate(s.tm, advance, 0)
    {end_x, end_y} = point(multiply(next_tm, s.ctm), 0, s.rise)
    {a, b, _, _, _, _} = multiply(s.tm, s.ctm)
    scale = max(:math.sqrt(a * a + b * b), 0.001)
    em = max(abs(s.size) * scale, 0.1)

    if text != "" do
      separator = separator(C.get(:last_text), x, y, em, a / scale, b / scale, text)
      C.output(separator <> text)

      C.put(
        :last_text,
        {end_x, end_y, em, a / scale, b / scale, String.ends_with?(text, [" ", "\n", "\t"])}
      )
    end

    show(%{s | tm: next_tm}, rest)
  end

  defp separator(nil, _, _, _, _, _, _), do: ""

  defp separator({px, py, pem, ux, uy, space}, x, y, em, vx, vy, text) do
    dx = x - px
    dy = y - py
    perpendicular = abs(-uy * dx + ux * dy)
    along = ux * dx + uy * dy

    cond do
      ux * vx + uy * vy < 0.8 or perpendicular > max(em, pem) * 0.55 ->
        "\n"

      along < -max(em, pem) * 2 ->
        "\n"

      along > min(em, pem) * 0.18 and not space and
          not String.starts_with?(text, [" ", "\n", "\t"]) ->
        " "

      true ->
        ""
    end
  end

  defp move(s, x, y) do
    line = translate(s.line, numeric!(x), numeric!(y))
    %{s | line: line, tm: line}
  end

  defp translate({a, b, c, d, e, f}, x, y), do: {a, b, c, d, e + x * a + y * c, f + x * b + y * d}

  defp matrix([a, b, c, d, e, f]),
    do: {numeric!(a), numeric!(b), numeric!(c), numeric!(d), numeric!(e), numeric!(f)}

  defp matrix(_), do: C.fail(:invalid_matrix)
  defp numeric!(n) when is_number(n) and abs(n) <= 1.0e8, do: n
  defp numeric!(_), do: C.fail(:invalid_number)

  defp multiply({a, b, c, d, e, f}, {g, h, i, j, k, l}) do
    result =
      {a * g + b * i, a * h + b * j, c * g + d * i, c * h + d * j, e * g + f * i + k,
       e * h + f * j + l}

    Enum.each(Tuple.to_list(result), &numeric!/1)
    result
  end

  defp point({a, b, c, d, e, f}, x, y), do: {x * a + y * c + e, x * b + y * d + f}
end
