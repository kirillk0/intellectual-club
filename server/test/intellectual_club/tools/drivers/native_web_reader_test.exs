defmodule IntellectualClub.Tools.Drivers.NativeWebReaderTest do
  use IntellectualClub.DataCase, async: true

  alias IntellectualClub.Tools.DocumentReader
  alias IntellectualClub.Tools.Drivers.NativeWebReader

  describe "HTML hyperlinks" do
    setup do
      %{user: actor} = user_fixture()

      tool =
        create_tool_instance!(actor,
          name: "Web Reader",
          type: "native-web-reader"
        )

      %{tool: tool}
    end

    test "preserves absolute destinations and visible link text", %{tool: tool} do
      html = ~S"""
      <html><body>
        <a href="https://example.org/docs?a=1&amp;b=2"><strong>Guide</strong> &amp; reference</a>
        <A title="Go > there" HREF='https://example.org/single'>Single quotes</A>
        <a href=https://example.org/bare>Bare address</a>
        <a data-href="https://wrong.example/" title="href='https://wrong.example/'"
           href="mailto:team@example.org">Contact</a>
      </body></html>
      """

      {:ok, server} = start_raw_http_server(200, "text/html", html)
      on_exit(fn -> stop_raw_http_server(server) end)

      assert {:ok, {text, _raw}} =
               NativeWebReader.execute(tool, "read_url", %{
                 "url" => "http://127.0.0.1:#{server.port}/page"
               })

      assert text =~ "[Guide & reference](https://example.org/docs?a=1&b=2)"
      assert text =~ "[Single quotes](https://example.org/single)"
      assert text =~ "[Bare address](https://example.org/bare)"
      assert text =~ "[Contact](mailto:team@example.org)"
      refute text =~ "wrong.example"
    end

    test "resolves relative paths, hosts, fragments and queries against the page URL", %{
      tool: tool
    } do
      links = [
        {"sibling", "next.html", "/docs/next.html"},
        {"parent", "../up", "/up"},
        {"root", "/root", "/root"},
        {"fragment", "#details", "/docs/page.html?lang=en#details"},
        {"query", "?lang=ru&amp;page=2", "/docs/page.html?lang=ru&page=2"},
        {"empty", "", "/docs/page.html?lang=en"}
      ]

      html =
        "<html><body>" <>
          Enum.map_join(links, "\n", fn {label, href, _} -> ~s(<a href="#{href}">#{label}</a>) end) <>
          ~s(<a href="//example.org/path">host</a></body></html>)

      {:ok, server} = start_raw_http_server(200, "text/html", html)
      on_exit(fn -> stop_raw_http_server(server) end)
      origin = "http://127.0.0.1:#{server.port}"

      assert {:ok, {text, _raw}} =
               NativeWebReader.execute(tool, "read_url", %{
                 "url" => origin <> "/docs/page.html?lang=en"
               })

      for {label, _, path} <- links do
        assert text =~ "[#{label}](#{origin}#{path})"
      end

      assert text =~ "[host](http://example.org/path)"
    end

    test "honors the first base href resolved against the page URL", %{tool: tool} do
      html = """
      <html><head>
        <base target="_blank"><base href="../assets/"><base href="https://wrong.example/">
      </head><body><a href="guide.html">Guide</a></body></html>
      """

      {:ok, server} = start_raw_http_server(200, "text/html", html)
      on_exit(fn -> stop_raw_http_server(server) end)

      assert {:ok, {text, _raw}} =
               NativeWebReader.execute(tool, "read_url", %{
                 "url" => "http://127.0.0.1:#{server.port}/docs/page.html"
               })

      assert text =~ "[Guide](http://127.0.0.1:#{server.port}/assets/guide.html)"
    end

    test "uses the final URL after redirects for relative destinations", %{tool: tool} do
      html = ~s(<html><body><a href="next.html">Next</a></body></html>)
      {:ok, destination} = start_raw_http_server(200, "text/html", html)
      final_url = "http://127.0.0.1:#{destination.port}/moved/page.html"
      {:ok, redirect} = start_raw_http_server(302, "text/plain", "", [{"Location", final_url}])

      on_exit(fn ->
        stop_raw_http_server(redirect)
        stop_raw_http_server(destination)
      end)

      assert {:ok, {text, raw}} =
               NativeWebReader.execute(tool, "read_url", %{
                 "url" => "http://127.0.0.1:#{redirect.port}/original"
               })

      assert raw["url"] == final_url
      assert text =~ "[Next](http://127.0.0.1:#{destination.port}/moved/next.html)"
    end

    test "escapes Markdown syntax while preserving decoded labels and destinations", %{tool: tool} do
      html = ~S"""
      <html><body>
        <a href="https://example.org/a(b)&#32;c?q=&quot;x&quot;&amp;n=&#49;">[A] *B* \ C &lt;D&gt;</a>
      </body></html>
      """

      {:ok, server} = start_raw_http_server(200, "text/html", html)
      on_exit(fn -> stop_raw_http_server(server) end)

      assert {:ok, {text, _raw}} =
               NativeWebReader.execute(tool, "read_url", %{
                 "url" => "http://127.0.0.1:#{server.port}/page"
               })

      assert text =~ ~S"[\[A\] \*B\* \\ C \<D\>](https://example.org/a%28b%29%20c?q=%22x%22&n=1)"
    end

    test "keeps anchors without href as text and omits non-readable markup", %{tool: tool} do
      html = """
      <html><body>
        <a name="section">Section</a><a href="/empty"></a>
        <!-- <a href="/comment">Comment link</a> -->
        <script><a href="/script">Script link</a></script>
        <style><a href="/style">Style link</a></style>
        <noscript><a href="/noscript">Noscript link</a></noscript>
      </body></html>
      """

      {:ok, server} = start_raw_http_server(200, "text/html", html)
      on_exit(fn -> stop_raw_http_server(server) end)

      assert {:ok, {text, _raw}} =
               NativeWebReader.execute(tool, "read_url", %{
                 "url" => "http://127.0.0.1:#{server.port}/page"
               })

      assert text =~ "Section"
      assert text =~ "[](http://127.0.0.1:#{server.port}/empty)"
      refute text =~ "[Section]"
      refute text =~ "link"
    end

    test "searches and caches Markdown destinations", %{tool: tool} do
      html = ~s(<html><body><a href="/target">Destination</a></body></html>)
      {:ok, server} = start_raw_http_server(200, "text/html", html)
      on_exit(fn -> stop_raw_http_server(server) end)
      url = "http://127.0.0.1:#{server.port}/page"
      link = "[Destination](http://127.0.0.1:#{server.port}/target)"

      for cached <- [false, true] do
        assert {:ok, {text, raw}} = NativeWebReader.execute(tool, "read_url", %{"url" => url})
        assert raw["cached"] == cached
        assert text =~ link
      end

      assert {:ok, {_text, raw}} =
               NativeWebReader.execute(tool, "search_url", %{"url" => url, "regex" => "/target"})

      assert raw["cached"]
      assert [%{"snippet" => snippet}] = raw["snippets"]
      assert snippet =~ link
    end

    test "re-extracts pages stored before Markdown hyperlinks were supported", %{tool: tool} do
      html = ~s(<html><body><a href="/target">Destination</a></body></html>)
      {:ok, server} = start_raw_http_server(200, "text/html", html)
      on_exit(fn -> stop_raw_http_server(server) end)
      url = "http://127.0.0.1:#{server.port}/page"
      cache_root = Path.join([System.tmp_dir!(), "club_web_reader_cache", "tool_#{tool.id}"])
      old_doc_id = DocumentReader.doc_id(url)

      assert {:ok, _cache} =
               DocumentReader.ensure_text_cache_ready(
                 cache_root,
                 tool.id,
                 old_doc_id,
                 "Destination without a link",
                 %{},
                 DocumentReader.config_from_map(%{})
               )

      assert {:ok, {text, raw}} = NativeWebReader.execute(tool, "read_url", %{"url" => url})
      refute raw["cached"]
      assert text =~ "[Destination](http://127.0.0.1:#{server.port}/target)"
    end
  end

  test "read_url rejects compressed bulk downloads before fetching" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, name: "Web Reader", type: "native-web-reader")

    assert {:error, message} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:1/data/products.csv.gz"
             })

    assert message =~ "compressed archives"
  end

  test "read_url rejects compressed content types before extraction" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, name: "Web Reader", type: "native-web-reader")

    {:ok, server} = start_raw_http_server(200, "application/gzip", "not really gzip")

    on_exit(fn -> stop_raw_http_server(server) end)

    assert {:error, message} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:#{server.port}/download"
             })

    assert message =~ "compressed archives"
  end

  test "read_url safely decompresses gzip content encoding" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        name: "Web Reader",
        type: "native-web-reader",
        config: %{"chunk_size_tokens" => 100}
      )

    body = "A gzip-compressed page with a readable needle."

    {:ok, server} =
      start_raw_http_server(200, "text/plain", :zlib.gzip(body), [
        {"Content-Encoding", "gzip"}
      ])

    on_exit(fn -> stop_raw_http_server(server) end)

    assert {:ok, {text, raw}} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:#{server.port}/gzip-page"
             })

    assert text =~ body
    assert raw["content_type"] == "text/plain"
  end

  test "read_url stops gzip decompression when expanded body exceeds the limit" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        name: "Web Reader",
        type: "native-web-reader",
        config: %{"max_download_bytes" => 1_024}
      )

    compressed = :zlib.gzip(:binary.copy("a", 1_000_000))
    assert byte_size(compressed) < 1_024

    {:ok, server} =
      start_raw_http_server(200, "text/plain", compressed, [{"Content-Encoding", "gzip"}])

    on_exit(fn -> stop_raw_http_server(server) end)

    assert {:error, "Decompressed body exceeds max_download_bytes limit."} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:#{server.port}/gzip-bomb"
             })
  end

  test "read_url rejects invalid gzip content" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, name: "Web Reader", type: "native-web-reader")

    {:ok, server} =
      start_raw_http_server(200, "text/plain", "not really gzip", [
        {"Content-Encoding", "gzip"}
      ])

    on_exit(fn -> stop_raw_http_server(server) end)

    assert {:error, "Invalid gzip response body."} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:#{server.port}/invalid-gzip"
             })
  end

  test "read_url returns a valid utf-8 error when upstream body is not utf-8" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, name: "Web Reader", type: "native-web-reader")

    body =
      <<"<html><body><h1> HTTP/1.1 ", 208, 194, 189, 168, 187, 225, 187, 176, 202, 167, 176, 220,
        "</h1></body></html>">>

    {:ok, server} = start_raw_http_server(400, "text/html", body)

    on_exit(fn -> stop_raw_http_server(server) end)

    assert {:error, message} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:#{server.port}/broken"
             })

    assert String.starts_with?(message, "HTTP error while fetching URL: 400.")
    assert String.valid?(message)
    assert message =~ "ÐÂ½¨»á»°Ê§°Ü"
  end

  test "read_url uses shared document pagination for text responses" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        name: "Web Reader",
        type: "native-web-reader",
        config: %{"chunk_size_tokens" => 10}
      )

    body = """
    alpha beta gamma delta epsilon zeta eta theta

    lambda mu needle nu xi omicron pi rho sigma

    final paragraph with enough words for another chunk
    """

    {:ok, server} = start_raw_http_server(200, "text/plain", body)

    on_exit(fn -> stop_raw_http_server(server) end)

    assert {:ok, {text, raw}} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:#{server.port}/text",
               "page" => 1
             })

    assert text =~ "Source: http://127.0.0.1:#{server.port}/text"
    assert text =~ "Page: 1 /"
    assert raw["pages_total"] >= 1
  end

  test "read_url extracts DOCX text responses" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        name: "Web Reader",
        type: "native-web-reader",
        config: %{"chunk_size_tokens" => 100}
      )

    {:ok, server} = start_raw_http_server(200, "application/zip", docx_payload())

    on_exit(fn -> stop_raw_http_server(server) end)

    assert {:ok, {text, raw}} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:#{server.port}/sample.docx",
               "page" => 1
             })

    assert text =~ "Source: http://127.0.0.1:#{server.port}/sample.docx"
    assert text =~ "Web DOCX needle paragraph"
    assert raw["content_type"] == "application/zip"
    assert raw["pages_total"] >= 1
  end

  test "rebuilding a document cache evicts expired entries with or without a READY marker" do
    cache_root =
      Path.join(System.tmp_dir!(), "ic-document-cache-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(cache_root) end)
    expired = {{2000, 1, 1}, {0, 0, 0}}

    ready_dir = Path.join(cache_root, "expired-ready")
    File.mkdir_p!(ready_dir)
    File.touch!(Path.join(ready_dir, "READY"), expired)

    unfinished_dir = Path.join(cache_root, "expired-unfinished")
    File.mkdir_p!(unfinished_dir)
    File.touch!(unfinished_dir, expired)

    cfg = DocumentReader.config_from_map(%{"cache_ttl_seconds" => 60})

    assert {:ok, {doc_dir, _meta, false}} =
             DocumentReader.ensure_text_cache_ready(
               cache_root,
               {:test, self()},
               "fresh",
               "Fresh text",
               %{},
               cfg
             )

    assert doc_dir == Path.join(cache_root, "fresh")
    refute File.exists?(ready_dir)
    refute File.exists?(unfinished_dir)

    assert {:ok, {^doc_dir, _meta, true}} =
             DocumentReader.ensure_text_cache_ready(
               cache_root,
               {:test, self()},
               "fresh",
               "Fresh text",
               %{},
               cfg
             )
  end

  defp start_raw_http_server(status, content_type, body, extra_headers \\ [])
       when is_integer(status) and is_binary(content_type) and is_binary(body) and
              is_list(extra_headers) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    {:ok, port} = :inet.port(listen_socket)
    parent = self()

    response = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " Test Response\r\n",
      "Content-Type: ",
      content_type,
      "\r\n",
      Enum.map(extra_headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: close\r\n\r\n",
      body
    ]

    pid =
      spawn(fn ->
        send(parent, {:raw_http_server_ready, self()})
        serve_raw_http_responses(listen_socket, response, 4)
      end)

    receive do
      {:raw_http_server_ready, ^pid} ->
        {:ok, %{pid: pid, port: port, listen_socket: listen_socket}}
    after
      1_000 -> {:error, :server_start_timeout}
    end
  end

  defp stop_raw_http_server(%{pid: pid, listen_socket: listen_socket}) do
    _ = :gen_tcp.close(listen_socket)

    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  defp serve_raw_http_responses(_listen_socket, _response, 0), do: :ok

  defp serve_raw_http_responses(listen_socket, response, remaining)
       when is_list(response) and is_integer(remaining) and remaining > 0 do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        serve_raw_http_responses(listen_socket, response, remaining - 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp docx_payload do
    document_xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r><w:t>Web DOCX needle paragraph</w:t></w:r>
        </w:p>
      </w:body>
    </w:document>
    """

    {:ok, {_name, bytes}} =
      :zip.create(~c"sample.docx", [{~c"word/document.xml", document_xml}], [:memory])

    bytes
  end
end
