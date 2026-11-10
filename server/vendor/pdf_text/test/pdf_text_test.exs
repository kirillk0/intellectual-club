defmodule PdfTextTest do
  use ExUnit.Case, async: true
  alias PdfText.Context

  defp stream(data, extra \\ ""),
    do: "<< /Length #{byte_size(data)} #{extra} >>\nstream\n" <> data <> "\nendstream"

  defp pdf(objects, trailer \\ "") do
    {data, offsets} =
      Enum.reduce(Enum.sort(objects), {"%PDF-1.7\n", %{}}, fn {id, object}, {data, offsets} ->
        {data <> "#{id} 0 obj\n" <> object <> "\nendobj\n", Map.put(offsets, id, byte_size(data))}
      end)

    xref = byte_size(data)

    sections =
      Enum.map(Enum.sort(offsets), fn {id, offset} ->
        "#{id} 1\n#{String.pad_leading(to_string(offset), 10, "0")} 00000 n \n"
      end)

    data <>
      "xref\n0 1\n0000000000 65535 f \n" <>
      IO.iodata_to_binary(sections) <>
      "trailer\n<< /Size #{Enum.max(Map.keys(objects)) + 1} /Root 1 0 R #{trailer} >>\nstartxref\n#{xref}\n%%EOF\n"
  end

  defp objects(content \\ "BT /F1 12 Tf 1 0 0 1 20 700 Tm (Hello safe PDF) Tj ET") do
    %{
      1 => "<< /Type /Catalog /Pages 2 0 R >>",
      2 => "<< /Type /Pages /Count 1 /Kids [3 0 R] /Resources << /Font << /F1 4 0 R >> >> >>",
      3 => "<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>",
      4 => "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
      5 => stream(content)
    }
  end

  defp extract(content), do: content |> objects() |> pdf() |> PdfText.extract()
  defp reasons(result), do: Enum.map(result.warnings, & &1.reason)

  defp context(fun, limits \\ []) do
    Context.run(
      %{
        limits: Map.merge(Context.defaults(), Map.new(limits)),
        timeout_ms: 5000,
        max_chars: 500_000,
        max_output_bytes: 2_097_152
      },
      fun
    )
  end

  test "extracts inherited resources and returns detached UTF-8 text" do
    input = objects() |> pdf()
    assert {:ok, r} = PdfText.extract(input)
    assert r.text == "Hello safe PDF"
    assert r.page_count == 1 and r.pages_extracted == 1
    assert r.version == "0.1.0" and not r.partial and not r.truncated
    assert r.warnings == []
    assert :binary.referenced_byte_size(r.text) == byte_size(r.text)
  end

  test "retains invisible text and does not add blind spaces between runs" do
    assert {:ok, r} = extract("BT /F1 12 Tf 3 Tr [(Hel) 10 (lo) -300 (world)] TJ (again) Tj ET")
    assert r.text == "Hello worldagain"
  end

  test "uses glyph widths, text matrices and graphics matrices for spacing" do
    o =
      objects(
        "q 2 0 0 2 10 10 cm BT /F1 10 Tf 1 0 0 1 0 100 Tm (A) Tj 1 0 0 1 5 100 Tm (B) Tj 1 0 0 1 15 100 Tm (C) Tj 0 -20 Td (D) Tj ET Q"
      )
      |> Map.put(
        4,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /FirstChar 65 /Widths [500 500 500 500] >>"
      )

    assert {:ok, r} = PdfText.extract(pdf(o))
    assert r.text == "AB C\nD"
  end

  test "ToUnicode handles Cyrillic, arrays, sequential ranges and multi-character UTF16" do
    cmap =
      "1 begincodespacerange <0000> <FFFF> endcodespacerange\n1 beginbfchar <0001> <0416> endbfchar\n2 beginbfrange <0002> <0003> [<0410> <00660069>] <0004> <0005> <0411> endbfrange"

    o =
      objects("BT /F1 12 Tf <00010002000300040005> Tj ET")
      |> Map.put(
        4,
        "<< /Type /Font /Subtype /Type0 /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>"
      )
      |> Map.put(6, "<< /Type /Font /Subtype /CIDFontType2 /DW 500 /W [1 [600] 2 5 500] >>")
      |> Map.put(7, stream(cmap))

    assert {:ok, r} = PdfText.extract(pdf(o))
    assert r.text == "ЖАfiБВ" and not r.partial
  end

  test "supports Differences, MacRoman and standard implicit font encodings" do
    for {encoding, bytes, expected} <- [
          {"<< /BaseEncoding /WinAnsiEncoding /Differences [65 /uni0416 /f_f_i] >>", "<4142>",
           "Жffi"},
          {"/MacRomanEncoding", "<80>", "Ä"},
          {"/StandardEncoding", "<AE>", "ﬁ"}
        ] do
      o =
        objects("BT /F1 12 Tf #{bytes} Tj ET")
        |> Map.put(
          4,
          "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding #{encoding} >>"
        )

      assert {:ok, r} = PdfText.extract(pdf(o))
      assert r.text == expected
    end
  end

  test "reads Forms with local resources and matrices but skips image programs" do
    o =
      objects("BT /F1 12 Tf (Before) Tj ET /Im Do /Fm Do")
      |> Map.put(
        3,
        "<< /Type /Page /Parent 2 0 R /Contents 5 0 R /Resources << /Font << /F1 4 0 R >> /XObject << /Fm 6 0 R /Im 7 0 R >> >> >>"
      )
      |> Map.put(
        6,
        stream("BT /F1 12 Tf (Form text) Tj ET", "/Subtype /Form /Matrix [1 0 0 1 0 -30]")
      )
      |> Map.put(7, stream("not a JPEG", "/Subtype /Image /Filter /DCTDecode"))

    assert {:ok, r} = PdfText.extract(pdf(o))
    assert r.text == "Before\nForm text"
    refute r.partial
  end

  test "rejects all encryption before text, even with an empty encryption dictionary" do
    assert {:error, :encrypted_pdf} = PdfText.extract(pdf(objects(), "/Encrypt << >>"))
    assert {:error, :encrypted_pdf} = PdfText.extract(pdf(objects(), "/Encrypt 99 0 R"))
  end

  test "unknown filters and inline images cannot produce a fake complete result" do
    for bad <- [
          stream("BT /F1 12 Tf (Garbage) Tj ET", "/Filter /UnknownDecode"),
          stream("BI /W 1 ID junk EI BT /F1 12 Tf (Garbage) Tj ET")
        ] do
      o = two_pages() |> Map.put(7, bad)
      assert {:ok, r} = PdfText.extract(pdf(o))
      assert r.partial and not r.truncated
      assert r.text == "Hello safe PDF"
      assert r.page_count == 2 and r.pages_extracted == 1
      assert length(r.warnings) == 1
    end
  end

  test "unsupported font is local and other fonts still extract" do
    o =
      objects("BT /Bad 12 Tf (Wrong) Tj /F1 12 Tf (Right) Tj ET")
      |> Map.put(
        3,
        "<< /Type /Page /Parent 2 0 R /Contents 5 0 R /Resources << /Font << /F1 4 0 R /Bad 6 0 R >> >> >>"
      )
      |> Map.put(6, "<< /Type /Font /Subtype /Type0 /Encoding /Identity-V >>")

    assert {:ok, r} = PdfText.extract(pdf(o))
    assert r.text == "Right" and r.partial
    assert :unsupported_font in reasons(r)
  end

  test "direct and indirect stream lengths are exact and cycles terminate" do
    data = "BT /F1 12 Tf (Indirect) Tj ET"

    o =
      objects()
      |> Map.put(5, "<< /Length 6 0 R >>\nstream\n#{data}\nendstream")
      |> Map.put(6, to_string(byte_size(data)))

    assert {:ok, %{text: "Indirect"}} = PdfText.extract(pdf(o))
    assert {:error, :no_text} = PdfText.extract(pdf(Map.put(o, 6, "5 0 R")))
    assert {:error, :no_text} = PdfText.extract(pdf(Map.put(o, 6, "999999999999")))
    cyclic = objects() |> Map.put(2, "<< /Type /Pages /Kids [2 0 R] /Count 1 >>")
    assert {:error, :page_cycle} = PdfText.extract(pdf(cyclic))
  end

  test "form cycles are diagnosed without discarding already extracted text" do
    o =
      objects("BT /F1 12 Tf (Safe) Tj ET /Fm Do")
      |> Map.put(
        3,
        "<< /Type /Page /Parent 2 0 R /Contents 5 0 R /Resources << /Font << /F1 4 0 R >> /XObject << /Fm 6 0 R >> >> >>"
      )
      |> Map.put(6, stream("/Fm Do", "/Subtype /Form"))

    assert {:ok, r} = PdfText.extract(pdf(o))
    assert r.text == "Safe" and r.partial
    assert :form_cycle in reasons(r)
  end

  test "bounded Flate verifies complete input and always closes its zlib handle" do
    compressed = :zlib.compress("BT /F1 12 Tf (Flate text) Tj ET")

    assert {:ok, %{text: "Flate text"}} =
             PdfText.extract(
               pdf(Map.put(objects(), 5, stream(compressed, "/Filter /FlateDecode")))
             )

    cut = binary_part(compressed, 0, byte_size(compressed) - 3)

    assert {:error, :no_text} =
             PdfText.extract(pdf(Map.put(objects(), 5, stream(cut, "/Filter /FlateDecode"))))

    bomb = :zlib.compress(:binary.copy("A", 1_000_000))
    o = Map.put(objects(), 5, stream(bomb, "/Filter /FlateDecode"))

    assert {:error, {:limit_exceeded, :stream_bytes}} =
             PdfText.extract(pdf(o), limits: [stream_bytes: 1024])
  end

  test "ASCII85 and PNG predictors decode and validate hostile dimensions" do
    context(fn ->
      assert PdfText.Codec.decode("87cURD_*#TDfTZ)+T~>", %{"Filter" => {:name, "ASCII85Decode"}}) ==
               "Hello, world!"

      raw = <<2, 1, 2, 3, 2, 3, 3, 3>>

      assert PdfText.Codec.decode(:zlib.compress(raw), %{
               "Filter" => {:name, "FlateDecode"},
               "DecodeParms" => %{"Predictor" => 12, "Columns" => 3}
             }) == <<1, 2, 3, 4, 5, 6>>

      assert catch_throw(
               PdfText.Codec.decode(:zlib.compress(raw), %{
                 "Filter" => {:name, "FlateDecode"},
                 "DecodeParms" => %{"Predictor" => 12, "Columns" => 999_999_999}
               })
             ) == {:pdf_limit, :predictor_row}
    end)
  end

  test "limits combine across pages and stop globally" do
    o =
      two_pages()
      |> Map.put(5, stream(:zlib.compress("BT /F1 12 Tf (First) Tj ET"), "/Filter /FlateDecode"))
      |> Map.put(7, stream(:zlib.compress("BT /F1 12 Tf (Second) Tj ET"), "/Filter /FlateDecode"))

    assert {:ok, r} = PdfText.extract(pdf(o), limits: [decoded_bytes: 40])
    assert r.text == "First" and r.truncated and r.partial
    assert r.pages_extracted == 1
    assert %{reason: :limit, limit: :decoded_bytes} in r.warnings
  end

  test "character and byte caps preserve UTF8 and stop before later malformed streams" do
    o = two_pages() |> Map.put(7, stream("bad", "/Filter /UnknownDecode"))
    assert {:ok, r} = PdfText.extract(pdf(o), max_chars: 5)
    assert r.text == "Hello" and r.truncated and r.partial
    assert reasons(r) == [:output_limit]

    o =
      objects("BT /F1 12 Tf <414141> Tj ET")
      |> Map.put(
        4,
        "<< /Type /Font /Subtype /Type1 /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [65 /uni0416] >> >>"
      )

    assert {:ok, r} = PdfText.extract(pdf(o), max_output_bytes: 5)
    assert r.text == "ЖЖ" and String.valid?(r.text)
  end

  test "large bfrange stays compact and invalid scalars fail safely" do
    context(fn ->
      cmap = PdfText.CMap.parse("1 beginbfrange <00000000> <FFFFFFFF> <0000> endbfrange")
      assert length(cmap.ranges) == 1 and map_size(cmap.chars) == 0
      assert PdfText.CMap.lookup(cmap, <<0, 0, 0, 65>>) == "A"

      assert catch_throw(PdfText.CMap.lookup(cmap, <<255, 255, 255, 255>>)) ==
               {:pdf_error, :invalid_cmap}
    end)
  end

  test "validates options, input, token/depth budgets and restores caller dictionary" do
    Process.put({Context, :context}, :sentinel)
    before = Process.get()
    assert {:error, :invalid_options} = PdfText.extract("%PDF-1.7", max_chars: -1)
    assert {:error, :invalid_options} = PdfText.extract("%PDF-1.7", limits: [depth: 1_000_000])
    assert {:error, :input_too_large} = PdfText.extract(pdf(objects()), max_input_bytes: 20)

    assert {:error, {:limit_exceeded, :tokens}} =
             PdfText.extract(pdf(objects()), limits: [tokens: 3])

    assert {:ok, _} = PdfText.extract(pdf(objects()))
    assert Process.get() == before

    context(
      fn ->
        assert catch_throw(PdfText.Parser.value("((((x))))")) == {:pdf_limit, :depth}
      end,
      depth: 2
    )

    Process.delete({Context, :context})
  end

  test "no text and malformed documents return stable bounded errors" do
    assert {:error, :no_text} = extract("q Q")
    assert {:error, :invalid_pdf} = PdfText.extract("not a PDF")
    assert {:error, :invalid_input} = PdfText.extract(nil)
    assert {:error, :missing_xref} = PdfText.extract("%PDF-1.7\n")
  end

  test "whitespace before a document limit does not hide the limit as no text" do
    o = two_pages() |> Map.put(5, stream("BT /F1 12 Tf ( ) Tj ET"))

    assert {:error, {:limit_exceeded, :operations}} =
             PdfText.extract(pdf(o), limits: [operations: 5])
  end

  test "text from an unfinished page remains separated from the next page" do
    o = two_pages() |> Map.put(5, stream("BT /F1 12 Tf (First page) Tj ]"))
    assert {:ok, result} = PdfText.extract(pdf(o))
    assert result.text == "First page\n\nSecond page"
    assert result.partial
    refute result.truncated
  end

  defp two_pages do
    objects()
    |> Map.put(
      2,
      "<< /Type /Pages /Count 999999999 /Kids [3 0 R 6 0 R] /Resources << /Font << /F1 4 0 R >> >> >>"
    )
    |> Map.put(6, "<< /Type /Page /Parent 2 0 R /Contents 7 0 R >>")
    |> Map.put(7, stream("BT /F1 12 Tf (Second page) Tj ET"))
  end

  defp xref_stream_pdf do
    compressed_objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
      "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    ]

    {header, body} =
      Enum.with_index(compressed_objects, 1)
      |> Enum.reduce({"", ""}, fn {obj, id}, {header, body} ->
        {header <> "#{id} #{byte_size(body)} ", body <> obj <> " "}
      end)

    data = "%PDF-1.7\n"
    o5 = byte_size(data)
    data = data <> "5 0 obj\n" <> stream("BT /F1 12 Tf (Object stream) Tj ET") <> "\nendobj\n"
    o6 = byte_size(data)

    data =
      data <>
        "6 0 obj\n" <>
        stream(
          :zlib.compress(header <> body),
          "/Type /ObjStm /N 4 /First #{byte_size(header)} /Filter /FlateDecode"
        ) <> "\nendobj\n"

    o7 = byte_size(data)

    rows =
      <<0, 0::32, 0::16>> <>
        IO.iodata_to_binary(for i <- 0..3, do: <<2, 6::32, i::16>>) <>
        <<1, o5::32, 0::16, 1, o6::32, 0::16, 1, o7::32, 0::16>>

    data <>
      "7 0 obj\n" <>
      stream(
        :zlib.compress(rows),
        "/Type /XRef /Size 8 /W [1 4 2] /Root 1 0 R /Filter /FlateDecode"
      ) <> "\nendobj\nstartxref\n#{o7}\n%%EOF\n"
  end

  test "xref and object streams resolve lazily including nonstandard free generation zero" do
    assert {:ok, r} = PdfText.extract(xref_stream_pdf())
    assert r.text == "Object stream" and not r.partial

    assert {:ok, r} =
             PdfText.extract(xref_stream_pdf(), limits: [cache_entries: 1, cache_bytes: 1024])

    assert r.text == "Object stream"
  end

  test "incremental revisions select newest objects and detect Prev cycles" do
    original = pdf(objects())
    [_, prev] = Regex.run(~r/startxref\n(\d+)/, original)
    offset = byte_size(original)
    updated = original <> "5 0 obj\n" <> stream("BT /F1 12 Tf (Updated) Tj ET") <> "\nendobj\n"
    xref = byte_size(updated)

    suffix =
      "xref\n5 1\n#{String.pad_leading(to_string(offset), 10, "0")} 00000 n \ntrailer\n<< /Size 6 /Root 1 0 R /Prev #{prev} >>\nstartxref\n#{xref}\n%%EOF\n"

    assert {:ok, %{text: "Updated"}} = PdfText.extract(updated <> suffix)
    cyclic = String.replace(suffix, "/Prev #{prev}", "/Prev #{xref}")
    assert {:error, :xref_cycle} = PdfText.extract(updated <> cyclic)
  end

  test "hybrid xref stream entries override free placeholders in the table" do
    original = xref_stream_pdf()
    [_, stream_offset] = Regex.run(~r/startxref\n(\d+)/, original)
    offset = byte_size(original)

    suffix =
      "xref\n0 5\n" <>
        String.duplicate("0000000000 00000 f \n", 5) <>
        "trailer\n<< /Size 8 /Root 1 0 R /XRefStm #{stream_offset} >>\nstartxref\n#{offset}\n%%EOF\n"

    assert {:ok, %{text: "Object stream", partial: false}} = PdfText.extract(original <> suffix)
  end

  test "deadline is enforced synchronously and caller flags and dictionary values survive" do
    before_flag = Process.info(self(), :trap_exit)

    for value <- [:absent, nil, %{private: :value}] do
      Process.put({Context, :context}, value)
      assert {:ok, _} = PdfText.extract(pdf(objects()))
      assert Process.get({Context, :context}) == value
    end

    context(fn ->
      Context.put(:deadline, System.monotonic_time(:millisecond) - 1)
      assert catch_throw(Context.tick(:tokens)) == {:pdf_limit, :timeout}
    end)

    assert Process.info(self(), :trap_exit) == before_flag
    Process.delete({Context, :context})
  end

  test "large multi-character mappings stop within the output budget" do
    mapping = String.duplicate("0061", 256)
    cmap = "1 beginbfchar <41> <#{mapping}> endbfchar"

    o =
      objects("BT /F1 12 Tf (#{String.duplicate("A", 20_000)}) Tj ET")
      |> Map.put(
        4,
        "<< /Type /Font /Subtype /Type1 /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>"
      )
      |> Map.put(6, stream(cmap))

    assert {:ok, r} = PdfText.extract(pdf(o), max_chars: 10, limits: [glyphs: 256])
    assert r.text == String.duplicate("a", 10)
    assert r.truncated and reasons(r) == [:output_limit]
  end

  test "xref entry budgets count sparse entries rather than maximum object IDs" do
    o = objects() |> Map.put(1, "<< /Type /Catalog /Pages 1000000000 0 R >>")
    o = o |> Map.put(1_000_000_000, Map.fetch!(o, 2)) |> Map.delete(2)
    assert {:ok, %{text: "Hello safe PDF"}} = PdfText.extract(pdf(o))

    assert {:error, {:limit_exceeded, :xref_entries}} =
             PdfText.extract(pdf(o), limits: [xref_entries: 2])
  end

  test "random truncations and mutations stay within the public tuple contract" do
    original = pdf(objects())
    :rand.seed(:exsss, {11, 23, 37})

    for _ <- 1..300 do
      offset = :rand.uniform(byte_size(original)) - 1

      data =
        if rem(offset, 2) == 0 do
          binary_part(original, 0, offset)
        else
          <<head::binary-size(^offset), _, tail::binary>> = original
          head <> <<:rand.uniform(256) - 1>> <> tail
        end

      result = PdfText.extract(data, timeout_ms: 100, limits: [tokens: 10_000])

      assert match?({:error, _}, result) or
               match?({:ok, %{text: _, partial: _, truncated: _}}, result)
    end
  end

  test "PDF names and operators never create atoms" do
    context(fn ->
      PdfText.Parser.value("/Warmup")
      before = :erlang.system_info(:atom_count)

      for n <- 1..2_000 do
        assert {{:name, _}, ""} = PdfText.Parser.value("/UntrustedName#{n}")
        assert {{:kw, _}, ""} = PdfText.Parser.value("UntrustedOperator#{n}")
      end

      assert :erlang.system_info(:atom_count) == before
    end)
  end

  test "ASCII85 treats a leading percent sign as encoded data, not a PDF comment" do
    context(fn ->
      assert PdfText.Codec.decode("%!!!!~>", %{"Filter" => {:name, "ASCII85Decode"}}) ==
               <<208_802_500::32>>
    end)
  end

  test "UTF16 surrogate pairs are decoded without replacing valid supplementary characters" do
    context(fn ->
      cmap = PdfText.CMap.parse("1 beginbfchar <41> <D83DDE00> endbfchar")
      assert PdfText.CMap.lookup(cmap, "A") == "😀"
      assert catch_throw(PdfText.CMap.unicode(<<0xD8, 0x3D>>)) == {:pdf_error, :invalid_cmap}
    end)
  end

  test "Contents arrays preserve operands and text state between streams" do
    o =
      objects("BT /F1 12 Tf (First)")
      |> Map.put(3, "<< /Type /Page /Parent 2 0 R /Contents [5 0 R 6 0 R] >>")
      |> Map.put(6, stream("Tj (Second) Tj ET"))

    assert {:ok, %{text: "FirstSecond", partial: false}} = PdfText.extract(pdf(o))
  end

  test "q and Q restore graphics and text parameters but not text matrices" do
    assert {:ok, r} = extract("BT /F1 12 Tf q (A) Tj Q (B) Tj ET")
    assert r.text == "AB" and not r.partial
    assert {:ok, r} = extract("BT /F1 12 Tf (Safe) Tj Tj ET")
    assert r.text == "Safe" and r.partial and :invalid_content in reasons(r)
  end

  defp capped_worker(fun) do
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.flag(:max_heap_size, %{
          size: div(256 * 1024 * 1024, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        fun.()
        :ok
      end)

    assert Task.await(task, 30_000) == :ok
  end

  test "ASCII85 decodes six MiB in bounded blocks within a capped worker" do
    capped_worker(fn ->
      groups = div(6 * 1024 * 1024, 4)

      for {encoded, word} <- [{"z", <<0::32>>}, {"!<N?+", <<1, 2, 3, 4>>}] do
        context(fn ->
          Context.put(:deadline, System.monotonic_time(:millisecond) + 25_000)
          input = :binary.copy(encoded, groups) <> "!!~>"
          decoded = PdfText.Codec.decode(input, %{"Filter" => {:name, "ASCII85Decode"}})
          assert decoded == :binary.copy(word, groups) <> <<0>>
          assert Context.get(:counts).decoded_bytes == groups * 4 + 1
        end)
      end
    end)
  end

  test "ASCII85 charges complete groups and partial tails before exceeding budgets" do
    for {input, limit, charged} <- [{"zz~>", 7, 4}, {"z!!~>", 4, 4}] do
      for budget <- [:stream_bytes, :decoded_bytes] do
        context(
          fn ->
            assert catch_throw(
                     PdfText.Codec.decode(input, %{"Filter" => {:name, "ASCII85Decode"}})
                   ) == {:pdf_limit, budget}

            assert Context.get(:counts).decoded_bytes == charged
          end,
          [{budget, limit}]
        )
      end
    end
  end

  test "many tiny outputs retain bounded chunks within a capped worker" do
    capped_worker(fn ->
      context(fn ->
        Context.put(:deadline, System.monotonic_time(:millisecond) + 25_000)
        Context.put(:max_chars, 2_000_000)

        Enum.each(1..2_000_000, fn _ -> Context.output("x") end)
        chunks = Context.get(:chunks)
        assert length(chunks) <= div(2_000_000, 8192) + 1
        assert Enum.all?(chunks, &(byte_size(&1) <= 16_384))
        assert IO.iodata_to_binary(Enum.reverse(chunks)) == :binary.copy("x", 2_000_000)
        assert Context.get(:chars) == 2_000_000
        assert Context.get(:output_bytes) == 2_000_000
        assert catch_throw(Context.output("y")) == :pdf_output_limit
        assert Context.get(:chunks) == chunks
      end)
    end)
  end

  test "chunk reads include pending UTF8 text and nested contexts restore buffered state" do
    context(fn ->
      prefix = :binary.copy("a", 8191)
      Context.output(prefix)
      snapshot = Context.get(:chunks)
      assert IO.iodata_to_binary(Enum.reverse(snapshot)) == prefix
      Context.output("😀")
      before = Process.get({Context, :context})

      assert catch_throw(
               context(fn ->
                 Context.output("nested")
                 throw(:nested)
               end)
             ) == :nested

      assert Process.get({Context, :context}) == before
      Context.put(:max_output_bytes, 8198)
      assert catch_throw(Context.output("ЖЖ")) == :pdf_output_limit
      chunks = Context.get(:chunks)
      assert IO.iodata_to_binary(Enum.reverse(chunks)) == prefix <> "😀Ж"
      assert Enum.all?(chunks, &String.valid?/1)
      assert Context.get(:chars) == 8193
      assert Context.get(:output_bytes) == 8197
      assert Context.get(:chunks) == chunks
      assert IO.iodata_to_binary(Enum.reverse(snapshot)) == prefix
    end)
  end

  test "a single large output is flushed in bounded UTF8 blocks" do
    context(fn ->
      text = :binary.copy("aЖ😀", 40_000)
      Context.output(text)
      chunks = Context.get(:chunks)
      assert Enum.all?(chunks, &(byte_size(&1) <= 16_384 and String.valid?(&1)))
      assert IO.iodata_to_binary(Enum.reverse(chunks)) == text
      assert Context.get(:chars) == 120_000
      assert Context.get(:output_bytes) == byte_size(text)
    end)
  end
end
