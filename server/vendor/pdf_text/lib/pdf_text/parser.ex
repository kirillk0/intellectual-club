defmodule PdfText.Parser do
  @moduledoc false
  alias PdfText.Context, as: C
  @white [0, 9, 10, 12, 13, 32]
  @delim [0, 9, 10, 12, 13, 32, ?(, ?), ?<, ?>, ?[, ?], ?{, ?}, ?/, ?%]
  def skip(data), do: skip(data, 0)

  defp skip(data, n) when rem(n, 1024) == 1023 do
    C.check()
    skip(data, 0)
  end

  defp skip(<<c, rest::binary>>, n) when c in @white, do: skip(rest, n + 1)
  defp skip(<<?%, rest::binary>>, n), do: comment(rest, n)
  defp skip(data, _), do: data
  defp comment(<<c, rest::binary>>, n) when c in [10, 13], do: skip(rest, n + 1)

  defp comment(<<_, rest::binary>>, n) do
    if rem(n, 1024) == 0, do: C.check()
    comment(rest, n + 1)
  end

  defp comment(<<>>, _), do: <<>>

  def value(data, depth \\ 0, refs \\ true) do
    C.tick(:tokens)
    C.bound(:depth, depth)
    parse(skip(data), depth, refs)
  end

  defp parse(<<"<<", rest::binary>>, d, r), do: dict(rest, %{}, d + 1, r, 0)
  defp parse(<<?[, rest::binary>>, d, r), do: array(rest, [], d + 1, r, 0)
  defp parse(<<?(, rest::binary>>, _, _), do: literal(rest, [], 0, 0)
  defp parse(<<?<, rest::binary>>, _, _), do: hex(rest, [], 0)

  defp parse(<<?/, rest::binary>>, _, _) do
    {word, tail} = word(rest)
    {{:name, name(word, [])}, tail}
  end

  defp parse(<<>>, _, _), do: C.fail(:unexpected_eof)

  defp parse(data, _, refs) do
    {word, tail} = word(data)

    case word do
      "" ->
        C.fail(:invalid_token)

      "true" ->
        {true, tail}

      "false" ->
        {false, tail}

      "null" ->
        {nil, tail}

      <<c, _::binary>> when c in ~c"+-.0123456789" ->
        if byte_size(word) > 32, do: C.fail(:invalid_number)
        number = number(word)

        if refs and is_integer(number) and number >= 0,
          do: reference(number, tail),
          else: {number, tail}

      _ ->
        {{:kw, word}, tail}
    end
  end

  defp number(w) do
    case Integer.parse(w) do
      {n, ""} ->
        n

      _ ->
        w = if String.starts_with?(w, "."), do: "0" <> w, else: w
        w = String.replace(w, "-.", "-0.") |> String.replace("+.", "+0.")
        w = if String.ends_with?(w, "."), do: w <> "0", else: w

        case Float.parse(w) do
          {n, ""} when abs(n) < 1.0e12 -> n
          _ -> C.fail(:invalid_number)
        end
    end
  end

  defp reference(n, tail) do
    data = skip(tail)

    case data do
      <<c, _::binary>> when c in ?0..?9 ->
        {w, rest} = word(data)

        if byte_size(w) <= 10 do
          case {Integer.parse(w), skip(rest)} do
            {{g, ""}, <<?R, after_r::binary>>} when g <= 65_535 ->
              if boundary?(after_r), do: {{:ref, n, g}, after_r}, else: {n, tail}

            _ ->
              {n, tail}
          end
        else
          {n, tail}
        end

      _ ->
        {n, tail}
    end
  end

  defp boundary?(<<>>), do: true
  defp boundary?(<<c, _::binary>>), do: c in @delim
  def word(data), do: word(data, data, 0)

  defp word(<<c, rest::binary>>, original, n) when c not in @delim do
    if rem(n, 1024) == 0, do: C.bound(:token_bytes, n)
    word(rest, original, n + 1)
  end

  defp word(rest, original, n) do
    C.bound(:token_bytes, n)
    {:binary.copy(binary_part(original, 0, n)), rest}
  end

  defp name(<<"#", a, b, rest::binary>>, acc),
    do: name(rest, [hex_digit(a) * 16 + hex_digit(b) | acc])

  defp name(<<c, rest::binary>>, acc), do: name(rest, [c | acc])
  defp name(<<>>, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  defp array(data, acc, d, refs, n) do
    C.bound(:collection, n)

    case skip(data) do
      <<?], rest::binary>> ->
        {Enum.reverse(acc), rest}

      rest ->
        {v, tail} = value(rest, d, refs)
        array(tail, [v | acc], d, refs, n + 1)
    end
  end

  defp dict(data, acc, d, refs, n) do
    C.bound(:collection, n)

    case skip(data) do
      <<">>", rest::binary>> ->
        {acc, rest}

      rest ->
        case value(rest, d, refs) do
          {{:name, key}, tail} ->
            {v, tail} = value(tail, d, refs)
            dict(tail, Map.put(acc, key, v), d, refs, n + 1)

          _ ->
            C.fail(:invalid_dictionary)
        end
    end
  end

  defp literal(data, acc, depth, n) do
    C.bound(:token_bytes, n)
    C.bound(:depth, depth)

    case data do
      <<?\\, ?\r, ?\n, rest::binary>> ->
        literal(rest, acc, depth, n)

      <<?\\, c, rest::binary>> when c in [10, 13] ->
        literal(rest, acc, depth, n)

      <<?\\, c, rest::binary>> when c in ?0..?7 ->
        {v, tail} = octal(rest, c - ?0, 1)
        literal(tail, [Bitwise.band(v, 255) | acc], depth, n + 1)

      <<?\\, c, rest::binary>> ->
        c = Map.get(%{?n => 10, ?r => 13, ?t => 9, ?b => 8, ?f => 12}, c, c)
        literal(rest, [c | acc], depth, n + 1)

      <<?(, rest::binary>> ->
        literal(rest, [?( | acc], depth + 1, n + 1)

      <<?), rest::binary>> when depth == 0 ->
        {{:str, acc |> Enum.reverse() |> :erlang.list_to_binary()}, rest}

      <<?), rest::binary>> ->
        literal(rest, [?) | acc], depth - 1, n + 1)

      <<13, 10, rest::binary>> ->
        literal(rest, [10 | acc], depth, n + 1)

      <<13, rest::binary>> ->
        literal(rest, [10 | acc], depth, n + 1)

      <<c, rest::binary>> ->
        literal(rest, [c | acc], depth, n + 1)

      <<>> ->
        C.fail(:unexpected_eof)
    end
  end

  defp octal(<<c, rest::binary>>, v, n) when c in ?0..?7 and n < 3,
    do: octal(rest, v * 8 + c - ?0, n + 1)

  defp octal(rest, v, _), do: {v, rest}

  defp hex(data, acc, n) do
    C.bound(:token_bytes, n)

    case data do
      <<?>, rest::binary>> ->
        digits = Enum.reverse(acc)
        digits = if rem(n, 2) == 1, do: digits ++ [0], else: digits
        bytes = for [a, b] <- Enum.chunk_every(digits, 2), into: <<>>, do: <<a * 16 + b>>
        {{:str, bytes}, rest}

      <<c, rest::binary>> when c in @white ->
        hex(rest, acc, n)

      <<c, rest::binary>> ->
        hex(rest, [hex_digit(c) | acc], n + 1)

      <<>> ->
        C.fail(:unexpected_eof)
    end
  end

  defp hex_digit(c) when c in ?0..?9, do: c - ?0
  defp hex_digit(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_digit(c) when c in ?A..?F, do: c - ?A + 10
  defp hex_digit(_), do: C.fail(:invalid_hex)
end
