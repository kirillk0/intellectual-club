defmodule IntellectualClub.Tools.Lua.HttpTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import IntellectualClub.TestEnv
  import IntellectualClub.TestHttpServer

  alias IntellectualClub.Tools.Lua.{Http, HttpTransport}

  @host "api.example.com"
  @url "https://api.example.com/v1/items"
  @public {93, 184, 216, 34}

  setup do
    put_app_env(:lua_tool_http, [])
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, "ok"))
    :ok
  end

  describe "permission validation" do
    test "accepts exact origins, the supported methods, path globs and optional secrets" do
      assert :ok = Http.validate_permissions([])
      assert :ok = Http.validate_permissions([rule()])
      assert :ok = Http.validate_permissions([rule() |> Map.delete("secrets")])

      assert :ok =
               Http.validate_permissions([
                 rule(
                   "http://API.example.com:8080/v1/*/items*",
                   ~w(GET HEAD POST PUT PATCH DELETE OPTIONS),
                   ["API_TOKEN"]
                 )
               ])

      assert :ok = Http.validate_permissions([rule("https://[2606:4700:4700::1111]:8443/v1/*")])
    end

    test "rejects unknown fields, malformed methods and secret lists" do
      for rules <- [
            nil,
            %{},
            [nil],
            [%{}],
            [Map.put(rule(), "extra", true)],
            [Map.put(rule(), "methods", [])],
            [Map.put(rule(), "methods", "GET")],
            [Map.put(rule(), "methods", ["get"])],
            [Map.put(rule(), "methods", ["TRACE"])],
            [Map.put(rule(), "methods", ["CONNECT"])],
            [Map.put(rule(), "methods", [:get])],
            [Map.put(rule(), "secrets", nil)],
            [Map.put(rule(), "secrets", [""])],
            [%{url: @url, methods: ["GET"]}],
            List.duplicate(rule(), 129)
          ] do
        assert {:error, message} = Http.validate_permissions(rules)
        assert is_binary(message)
      end
    end

    test "rejects wildcard authorities, credentials, queries, fragments and invalid ports" do
      for url <- [
            "https://*.example.com/v1/*",
            "https://api.*.com/v1/*",
            "*://api.example.com/*",
            "ftp://api.example.com/v1/*",
            "//api.example.com/v1/*",
            "https://user:pass@api.example.com/*",
            "https://api.example.com/v1/*?",
            "https://api.example.com/v1/*?a=b",
            "https://api.example.com/v1/*#",
            "https://api.example.com:0/*",
            "https://api.example.com:65536/*",
            "https://api.example.com:/*",
            "https://api.example.com:0443/*",
            "https://api.example.com./*",
            "https://api.example.com/v1/[ab]",
            "https://api.example.com/v1/%2a",
            "https://[fe80::1%25en0]/*"
          ] do
        assert {:error, _} = Http.validate_permissions([rule(url)]), url
      end
    end
  end

  describe "method, origin and path authorization" do
    test "matches the whole normalized path and permits only the requested method" do
      rules = [rule("https://api.example.com/v1/*/item*", ["GET", "POST"])]

      for method <- ["GET", "get", "POST", "post"] do
        assert {:ok, _} =
                 request(
                   %{"url" => "https://api.example.com/v%31/group/items/42", "method" => method},
                   rules
                 )
      end

      for url <- [
            "https://api.example.com/v11/group/items",
            "https://api.example.com/v1/items",
            "https://api.example.com/V1/a/items",
            "https://evil.example.com/v1/a/items",
            "http://api.example.com/v1/a/items",
            "https://api.example.com:444/v1/a/items"
          ] do
        assert {:error, "HTTP request is not permitted"} = request(%{"url" => url}, rules)
      end

      assert {:error, "HTTP request is not permitted"} = request(%{"method" => "DELETE"})
      assert {:error, _} = request(%{"method" => "CONNECT"})
      assert {:error, _} = request(%{"method" => "TRACE"})
      assert {:error, _} = request(%{"method" => "GET\r\nHost: localhost"})
      assert {:error, _} = request(%{"method" => 1})
    end

    test "normalizes host casing, default ports and an empty path without widening access" do
      assert {:ok, _} = request(%{"url" => "https://API.EXAMPLE.COM:443/v1/items"})

      assert {:ok, _} =
               request(%{"url" => "https://api.example.com"}, [rule("https://api.example.com/")])

      assert {:error, _} =
               request(%{"url" => "https://api.example.com/v1/items/more"}, [rule(@url)])

      assert {:error, _} = request(%{}, [])
    end

    test "rejects traversal and ambiguous paths before DNS or transport" do
      resolver = fn _ -> flunk("unsafe paths must not reach DNS") end

      for path <- [
            "/v1/../admin",
            "/v1/./items",
            "/v1/%2e%2e/admin",
            "/v1/.%2E/admin",
            "/v1/%252e%252e/admin",
            "/v1/%25252e%25252e/admin",
            "/v1/..%2fadmin",
            "/v1/%5c..%5cadmin",
            "/v1/\\admin",
            "/v1//admin",
            "//v1/items",
            "/v1/%00",
            "/v1/%0d%0aHost:localhost",
            "/v1/%zz",
            "/v1/%",
            "/v1/%3fadmin",
            "/v1/%23admin",
            "/v1/..;ignored/admin",
            "/v1/%ff"
          ] do
        assert {:error, _} =
                 request(%{"url" => "https://api.example.com" <> path}, [rule()], %{},
                   resolver: resolver
                 ),
               path

        assert {:error, _} = Http.validate_permissions([rule("https://api.example.com" <> path)]),
               path
      end
    end

    test "rejects request credentials, fragments, ambiguous IP syntax and non-HTTP URLs" do
      for url <- [
            "https://user:secret@api.example.com/v1/items",
            @url <> "#secret",
            "file:///etc/passwd",
            "gopher://api.example.com/v1/items",
            "https://127.1/v1/items",
            "https://2130706433/v1/items",
            "https://0x7f000001/v1/items",
            "https://api.example.com:99999/v1/items",
            @url <> "\n"
          ] do
        assert {:error, _} = request(%{"url" => url}), url
      end
    end
  end

  describe "public address policy and connection pinning" do
    test "blocks private, loopback, link-local, metadata, multicast and reserved IPv4" do
      for text <- ~w(0.0.0.0 0.1.2.3 10.0.0.1 100.64.0.1 100.100.100.200 127.0.0.1
                     169.254.169.254 169.254.170.2 172.16.0.1 172.31.255.255 192.0.0.9 192.0.2.1
                     192.88.99.1 192.168.1.1 198.18.0.1 198.19.255.255 198.51.100.1 203.0.113.1
                     224.0.0.1 239.255.255.255 240.0.0.1 255.255.255.255 168.63.129.16) do
        assert_blocked_address(text)
      end
    end

    test "blocks non-global IPv6, mapped IPv4 and reserved global-unicast subranges" do
      for text <-
            ~w(:: ::1 ::ffff:127.0.0.1 ::ffff:8.8.8.8 ::127.0.0.1 64:ff9b::a00:1 64:ff9b:1::1
                     100::1 fc00::1 fd00:ec2::254 fe80::1 fec0::1 ff02::1 2001::1 2001:2::1
                     2001:10::1 2001:20::1 2001:db8::1 2002:7f00:1::1 3fff::1 4000::1) do
        assert_blocked_address(text)
      end
    end

    test "rejects mixed DNS answers, malformed results and DNS failures" do
      for result <- [
            {:ok, [@public, {127, 0, 0, 1}]},
            {:ok, [{127, 0, 0, 1}, @public]},
            {:ok, [@public, {0, 0, 0, 0, 0, 0, 0, 1}]},
            {:ok, []},
            {:ok, ["8.8.8.8"]},
            {:ok, [{8, 8, 8, 999}]},
            {:ok, [{1, 2}]},
            {:error, :timeout},
            {:error, :nxdomain}
          ] do
        assert {:error, _} =
                 request(%{}, [rule()], %{},
                   resolver: fn _ -> result end,
                   adapter: fn _ -> flunk("unsafe DNS reached transport") end
                 )
      end
    end

    test "pins one checked address and preserves Host, TLS SNI and hostname verification" do
      calls = start_supervised!({Agent, fn -> 0 end})
      parent = self()

      resolver = fn host ->
        assert host == @host
        count = Agent.get_and_update(calls, &{&1, &1 + 1})
        {:ok, [if(count == 0, do: @public, else: {127, 0, 0, 1})]}
      end

      adapter = fn req ->
        send(parent, {:pinned, req.private.ic_lua_http_address})
        assert req.url.host == @host
        assert req.headers["host"] == [@host]
        assert req.options.connect_options[:hostname] == @host
        assert req.options.connect_options[:protocols] == [:http1]
        assert req.options.connect_options[:transport_opts][:verify] == :verify_peer
        refute Keyword.has_key?(req.options.connect_options[:transport_opts], :verify_fun)
        refute Keyword.has_key?(req.options.connect_options, :proxy)
        assert req.options.connect_options[:transport_opts][:timeout] == 3_000
        assert req.options.receive_timeout == 5_000
        assert req.options.request_timeout == 10_000
        assert req.options.connect_options[:max_header_list_size] == 32_768
        assert req.request_steps == [] and req.response_steps == [] and req.error_steps == []
        assert req.options.retry == false and req.options.redirect == false
        assert req.options.raw == true and req.options.compressed == false
        plug_adapter(req)
      end

      assert {:ok, _} = request(%{}, [rule()], %{}, resolver: resolver, adapter: adapter)
      assert_receive {:pinned, @public}
      assert Agent.get(calls, & &1) == 1
    end

    test "supports public literal IPv4 and IPv6 without re-resolving them" do
      for text <- ["8.8.8.8", "2606:4700:4700::1111"] do
        host = if String.contains?(text, ":"), do: "[#{text}]", else: text
        url = "https://#{host}:8443/v1/items"

        adapter = fn req ->
          assert req.private.ic_lua_http_address == ip(text)
          assert req.headers["host"] == ["#{host}:8443"]

          assert req.options.connect_options[:transport_opts][:inet6] ==
                   String.contains?(text, ":")

          plug_adapter(req)
        end

        assert {:ok, _} =
                 request(%{"url" => url}, [rule(url)], %{},
                   resolver: fn _ -> flunk("literal IP was resolved") end,
                   adapter: adapter
                 )
      end
    end
  end

  describe "strict request arguments and headers" do
    test "does not accept arbitrary Req, transport, credential or policy options" do
      for name <-
            ~w(adapter plug auth connect_options transport_opts proxy unix_socket retry redirect
                     receive_timeout allow_private max_response_body_bytes finch into options) do
        assert {:error, _} = request(%{name => true}), name
      end

      assert {:error, _} = request(%{method: "GET"})
      assert {:error, _} = Http.request([], [rule()], %{})
      assert {:error, _} = request(%{}, [rule()], %{}, allow_private: true)
    end

    test "ignores global Req defaults and plugins" do
      put_app_env(
        :default_options,
        [
          auth: {:bearer, "global-secret"},
          proxy: "localhost",
          plugins: [fn _ -> flunk("global plugin ran") end]
        ],
        :req
      )

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert Plug.Conn.get_req_header(conn, "accept-encoding") == ["identity"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, _} = request()
    end

    test "rejects Host, proxy, hop-by-hop, framing and routing overrides in either header map" do
      for header <-
            ~w(Host HOST Proxy Connection Keep-Alive Proxy-Authorization Proxy-Connection TE Trailer
                       Transfer-Encoding Upgrade Content-Length Expect Accept-Encoding Content-Encoding
                       Forwarded X-Forwarded-Host X-Forwarded-For Via X-HTTP-Method-Override X-Original-URL) do
        assert {:error, _} = request(%{"headers" => %{header => "value"}}), header

        assert {:error, _} =
                 request(
                   %{"secret_headers" => %{header => "TOKEN"}},
                   [rule(@url, ["GET"], ["TOKEN"])],
                   %{"TOKEN" => "value"}
                 ),
               header
      end
    end

    test "rejects invalid, duplicate or injected headers" do
      for headers <- [
            %{"bad header" => "x"},
            %{"x:a" => "x"},
            %{"" => "x"},
            %{"x" => "a\r\nb"},
            %{"x" => "\0"},
            %{"x" => "\t"},
            %{"x" => ["a", "b"]},
            %{"x" => 1},
            %{"x" => "one", "X" => "two"},
            %{:x => "one"},
            [],
            nil
          ] do
        assert {:error, _} = request(%{"headers" => headers})
      end

      assert {:error, _} =
               request(
                 %{"headers" => %{"authorization" => "literal"}, "bearer_secret" => "TOKEN"},
                 [rule(@url, ["GET"], ["TOKEN"])],
                 %{"TOKEN" => "token-value"}
               )
    end

    test "supports scalar query values, JSON and UTF-8 text without leaking options" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.query_params == %{"old" => "1", "q" => "a b&c", "n" => "2", "yes" => "true"}
        assert conn.body_params == %{"message" => "Привет"}
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["custom"]
        Req.Test.json(conn, %{"received" => true})
      end)

      assert {:ok, %{"status" => 200, "json" => %{"received" => true}}} =
               request(
                 %{
                   "method" => "POST",
                   "url" => @url <> "?old=1",
                   "query" => %{"q" => "a b&c", "n" => 2, "yes" => true},
                   "json" => %{"message" => "Привет"},
                   "headers" => %{"X-Custom" => "custom"}
                 },
                 [rule(@url, ["POST"])]
               )

      Req.Test.stub(__MODULE__, fn conn ->
        assert Req.Test.raw_body(conn) == "plain text"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, %{"body" => "", "json" => nil}} = request(%{"body" => "plain text"})

      for query <- [%{"nested" => %{}}, %{"list" => []}, %{"nil" => nil}, %{:atom => "x"}, []] do
        assert {:error, _} = request(%{"query" => query})
      end

      assert {:error, _} = request(%{"json" => %{}, "body" => "text"})
      assert {:error, _} = request(%{"body" => %{}})
    end
  end

  describe "secret authorization and redaction" do
    test "requires both one matching permission rule and the actor-authorized secret map" do
      params = %{"bearer_secret" => "TOKEN", "secret_headers" => %{"X-Key" => "KEY"}}
      secrets = %{"TOKEN" => "token-value", "KEY" => "key-value"}
      allowed = [rule(@url, ["GET"], ["TOKEN", "KEY"])]

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-value"]
        assert Plug.Conn.get_req_header(conn, "x-key") == ["key-value"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, _} = request(params, allowed, secrets)

      for {rules, supplied} <- [
            {[rule()], secrets},
            {allowed, %{}},
            {allowed, Map.delete(secrets, "KEY")},
            {[rule(@url, ["POST"], ["TOKEN", "KEY"])], secrets},
            {[rule("https://other.example.com/*", ["GET"], ["TOKEN", "KEY"])], secrets},
            {[rule(@url, ["GET"], ["TOKEN"]), rule(@url, ["GET"], ["KEY"])], secrets}
          ] do
        assert {:error, _} = request(params, rules, supplied)
      end
    end

    test "rejects invalid values and conflicting secret headers" do
      rules = [rule(@url, ["GET"], ["TOKEN"])]

      for value <- [nil, 123, "", "token\r\nX-Injected: yes", <<255>>] do
        assert {:error, _} = request(%{"bearer_secret" => "TOKEN"}, rules, %{"TOKEN" => value})
      end

      assert {:error, _} =
               request(
                 %{"bearer_secret" => "TOKEN", "secret_headers" => %{"Authorization" => "TOKEN"}},
                 rules,
                 %{"TOKEN" => "token"}
               )

      assert {:error, _} = request(%{"bearer_secret" => []}, rules, %{"TOKEN" => "token"})
    end

    test "redacts every authorized value in body, header names/values and recursively decoded JSON" do
      token = "sensitive-value"
      unused = "unused-sensitive"

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-#{token}", "Bearer #{token} #{unused}")
        |> Req.Test.json(%{
          token => [%{"nested" => "prefix #{token} suffix"}],
          "unused" => unused
        })
      end)

      assert {:ok, result} =
               request(%{"bearer_secret" => "TOKEN"}, [rule(@url, ["GET"], ["TOKEN"])], %{
                 "TOKEN" => token,
                 "UNUSED" => unused
               })

      refute inspect(result) =~ token
      refute inspect(result) =~ unused
      assert result["json"]["[REDACTED]"] == [%{"nested" => "prefix [REDACTED] suffix"}]
      assert result["headers"]["x-[REDACTED]"] == ["Bearer [REDACTED] [REDACTED]"]
    end

    test "redacts JSON-unescaped values, numeric values and secrets split across chunks" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, ~s({"escaped":"s\u0065cret-value","split":"secret-))
        {:ok, conn} = Plug.Conn.chunk(conn, ~s(value","number":123456789}))
        conn
      end)

      assert {:ok, result} =
               request(%{}, [rule()], %{"TOKEN" => "secret-value", "NUMBER" => "123456789"})

      assert result["json"] == %{
               "escaped" => "[REDACTED]",
               "split" => "[REDACTED]",
               "number" => "[REDACTED]"
             }

      refute result["body"] =~ "secret-value"
      refute result["body"] =~ "123456789"
      assert Jason.decode!(result["body"]) == result["json"]
    end

    test "handles overlapping secrets and replacement-boundary collisions without exposing them" do
      Req.Test.stub(
        __MODULE__,
        &Plug.Conn.send_resp(&1, 200, "long-secret short-secret ab[REDACTED]c")
      )

      secrets = %{"A" => "secret", "B" => "long-secret", "C" => "[REDACTED]", "D" => "abc"}
      assert {:ok, result} = request(%{}, [rule()], secrets)
      for value <- Map.values(secrets), do: refute(result["body"] =~ value)
    end

    test "never returns or logs exception details, request credentials or resolver errors" do
      secret = "never-log-this-credential"

      log =
        capture_log(fn ->
          for adapter <- [
                fn _ -> raise "request auth=#{secret}" end,
                fn _ -> throw(secret) end,
                fn _ -> exit(secret) end,
                fn req -> {req, RuntimeError.exception(secret)} end
              ] do
            assert {:error, message} =
                     request(
                       %{"bearer_secret" => "TOKEN"},
                       [rule(@url, ["GET"], ["TOKEN"])],
                       %{"TOKEN" => secret},
                       adapter: adapter
                     )

            refute message =~ secret
          end

          assert {:error, message} =
                   request(%{}, [rule()], %{"TOKEN" => secret},
                     resolver: fn _ -> raise secret end
                   )

          refute message =~ secret
        end)

      refute log =~ secret
      refute log =~ "authorization"
      assert {:error, message} = request(%{"method" => "TRACE"}, [rule()], %{"TOKEN" => "HTTP"})
      refute message =~ "HTTP"
    end
  end

  describe "redirects, retries and resource bounds" do
    test "returns redirect and transient-error responses without following or retrying" do
      parent = self()

      for status <- [301, 302, 303, 307, 308, 408, 429, 500, 502, 503, 504] do
        Req.Test.stub(__MODULE__, fn conn ->
          send(parent, {:attempt, status})

          conn
          |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data")
          |> Plug.Conn.put_resp_header("retry-after", "999")
          |> Plug.Conn.send_resp(status, "response")
        end)

        assert {:ok, %{"status" => ^status, "body" => "response"}} = request()
        assert_receive {:attempt, ^status}
        refute_receive {:attempt, ^status}, 0
      end
    end

    test "does not retry transport errors" do
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, :attempt)
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, "HTTP transport failed"} = request()
      assert_receive :attempt
      refute_receive :attempt, 0
    end

    test "bounds serialized request bodies, URLs and injected request headers before DNS" do
      resolver = fn _ -> flunk("oversized request reached DNS") end
      put_app_env(:lua_tool_http, max_request_body_bytes: 8)

      for params <- [
            %{"body" => "123456789"},
            %{"json" => "1234567"},
            %{"body" => String.duplicate("я", 5)}
          ] do
        assert {:error, _} = request(params, [rule()], %{}, resolver: resolver)
      end

      put_app_env(:lua_tool_http, max_url_bytes: 64)

      assert {:error, _} =
               request(%{"query" => %{"q" => String.duplicate("x", 65)}}, [rule()], %{},
                 resolver: resolver
               )

      put_app_env(:lua_tool_http, max_request_header_bytes: 128)

      assert {:error, _} =
               request(
                 %{"bearer_secret" => "TOKEN"},
                 [rule(@url, ["GET"], ["TOKEN"])],
                 %{"TOKEN" => String.duplicate("x", 128)},
                 resolver: resolver
               )

      put_app_env(:lua_tool_http, max_headers: 2)

      assert {:error, _} =
               request(%{"headers" => %{"x-custom" => "one"}}, [rule()], %{}, resolver: resolver)
    end

    test "accepts exact body boundaries and assembles UTF-8 split across chunks" do
      put_app_env(:lua_tool_http, max_request_body_bytes: 8, max_response_body_bytes: 8)

      Req.Test.stub(__MODULE__, fn conn ->
        assert Req.Test.raw_body(conn) == "12345678"
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, <<0xD0>>)
        {:ok, conn} = Plug.Conn.chunk(conn, <<0xAF>> <> "123456")
        conn
      end)

      assert {:ok, %{"body" => "Я123456"}} = request(%{"body" => "12345678"})
    end

    test "halts streaming before appending an over-budget chunk for every status" do
      put_app_env(:lua_tool_http, max_response_body_bytes: 16)
      parent = self()

      for status <- [200, 302, 500] do
        adapter = fn req ->
          response = Req.Response.new(status: status)

          Enum.reduce_while(
            ["12345678", "abcdefgh", "!", "must-not-be-read"],
            {req, response},
            fn data, acc ->
              send(parent, {:chunk, data})
              req.into.({:data, data}, acc)
            end
          )
        end

        assert {:error, "HTTP response body is too large"} =
                 request(%{}, [rule()], %{}, adapter: adapter)

        assert_receive {:chunk, "12345678"}
        assert_receive {:chunk, "abcdefgh"}
        assert_receive {:chunk, "!"}
        refute_receive {:chunk, "must-not-be-read"}, 0
      end
    end

    test "rejects compressed responses before decoding, even with empty or deceptively small bodies" do
      put_app_env(:lua_tool_http, max_response_body_bytes: 128)

      for {encoding, body} <- [
            {"gzip", :zlib.gzip(String.duplicate("x", 100_000))},
            {"br", ""},
            {"deflate", "small"},
            {"identity, gzip", ""}
          ] do
        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-encoding", encoding)
          |> Plug.Conn.send_resp(200, body)
        end)

        assert {:error, _} = request()
      end
    end

    test "rejects oversized response metadata, invalid UTF-8 and declared oversize" do
      put_app_env(:lua_tool_http, max_response_header_bytes: 64)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-long", String.duplicate("x", 65))
        |> Plug.Conn.send_resp(200, "")
      end)

      assert {:error, _} = request()
      put_app_env(:lua_tool_http, max_headers: 4)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-one", "1")
        |> Plug.Conn.put_resp_header("x-two", "2")
        |> Plug.Conn.put_resp_header("x-three", "3")
        |> Plug.Conn.put_resp_header("x-four", "4")
        |> Plug.Conn.send_resp(200, "")
      end)

      assert {:error, _} = request()
      put_app_env(:lua_tool_http, max_response_body_bytes: 8)

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_header("content-length", "9") |> Plug.Conn.send_resp(200, "")
      end)

      assert {:error, _} = request()
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, <<255, 254>>))
      assert {:error, "HTTP response body is not UTF-8 text"} = request()
    end

    test "enforces the per-request deadline during DNS and adapter execution without leaving workers" do
      put_app_env(:lua_tool_http, request_timeout_ms: 30)
      parent = self()

      block = fn _ ->
        send(parent, {:blocked_worker, self()})

        receive do
          :never -> {:error, :unused}
        end
      end

      for options <- [[resolver: block], [adapter: block]] do
        assert {:error, "HTTP request deadline exceeded"} = request(%{}, [rule()], %{}, options)
        assert_receive {:blocked_worker, pid}
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :noproc}
      end
    end
  end

  test "keeps absent JSON nil and rejects non-text response header values" do
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, "not json"))
    assert {:ok, %{"json" => nil}} = request(%{}, [rule()], %{"TOKEN" => "null"})

    adapter = fn req ->
      response = Req.Response.new(status: 200, headers: %{"x-invalid" => [<<255>>]})
      {_action, result} = req.into.({:data, ""}, {req, response})
      result
    end

    assert {:error, _} = request(%{}, [rule()], %{}, adapter: adapter)
  end

  test "cancels the socket-owning worker when the invoking process is killed" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        request(%{}, [rule()], %{},
          resolver: fn _ ->
            send(parent, {:dns_worker, self()})

            receive do
              :never -> {:error, :unused}
            end
          end
        )
      end)

    assert_receive {:dns_worker, worker}
    ref = Process.monitor(worker)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert Task.yield(task) == {:exit, :killed}
  end

  describe "real local transport through the trusted test adapter" do
    test "retains original TLS SNI and hostname verification when dialing a pinned IP" do
      parent = self()

      tls =
        :public_key.pkix_test_data(%{
          root: [digest: :sha256, key: {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}],
          peer: [
            digest: :sha256,
            key: {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}},
            extensions: [
              {:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"api.example.com"}]}
            ]
          ]
        })

      tls =
        Keyword.put(tls, :sni_fun, fn hostname ->
          send(parent, {:tls_sni, hostname})
          []
        end)

      server =
        start_supervised!(
          {Bandit,
           [
             scheme: :https,
             ip: {127, 0, 0, 1},
             port: 0,
             plug: fn conn, _opts ->
               send(parent, {:tls_http_host, conn.host})
               Plug.Conn.send_resp(conn, 200, "verified")
             end,
             thousand_island_options: [transport_options: tls]
           ]}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      url = "https://api.example.com:#{port}/v1/items"

      trusted_ca_adapter = fn req ->
        assert req.options.connect_options[:transport_opts][:verify] == :verify_peer

        req =
          update_in(
            req.options.connect_options[:transport_opts],
            &Keyword.put(&1, :cacerts, tls[:cacerts])
          )

        local_adapter().(req)
      end

      assert {:ok, %{"body" => "verified"}} =
               request(%{"url" => url}, [rule(url)], %{}, adapter: trusted_ca_adapter)

      assert_receive {:tls_sni, ~c"api.example.com"}
      assert_receive {:tls_http_host, "api.example.com"}

      wrong_host = "https://wrong.example.com:#{port}/v1/items"

      capture_log(fn ->
        assert {:error, "HTTP transport failed"} =
                 request(%{"url" => wrong_host}, [rule(wrong_host)], %{},
                   adapter: trusted_ca_adapter
                 )

        assert {:error, "HTTP transport failed"} =
                 request(%{"url" => url}, [rule(url)], %{}, adapter: local_adapter())
      end)

      refute_receive {:tls_http_host, _}, 0
    end

    test "connects to the pinned tuple without resolving the Host and preserves port, path and body" do
      parent = self()

      {_, port} =
        start_http_server!(fn conn, _opts ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:wire, conn.host, conn.port, conn.request_path, conn.query_string, body})

          conn =
            conn |> Plug.Conn.put_resp_header("x-result", "yes") |> Plug.Conn.send_chunked(200)

          {:ok, conn} = Plug.Conn.chunk(conn, "{\"ok\":")
          {:ok, conn} = Plug.Conn.chunk(conn, "true}")
          conn
        end)

      url = "http://no-dns-lookup.invalid:#{port}/v1/items?x=1"
      rules = [rule("http://no-dns-lookup.invalid:#{port}/v1/*", ["POST"])]

      assert {:ok, result} =
               request(%{"url" => url, "method" => "POST", "body" => "payload"}, rules, %{},
                 adapter: local_adapter()
               )

      assert result["json"] == %{"ok" => true}
      assert result["headers"]["x-result"] == ["yes"]
      assert_receive {:wire, "no-dns-lookup.invalid", ^port, "/v1/items", "x=1", "payload"}
    end

    test "bounds socket reads and closes the connection on timeout" do
      put_app_env(:lua_tool_http, receive_timeout_ms: 30, request_timeout_ms: 1_000)
      parent = self()

      {_, port} =
        start_http_server!(fn conn, _opts ->
          send(parent, {:server_waiting, self()})

          receive do
            :release -> Plug.Conn.send_resp(conn, 200, "late")
          end
        end)

      url = "http://api.example.com:#{port}/v1/items"

      assert {:error, "HTTP transport failed"} =
               request(%{"url" => url}, [rule(url)], %{}, adapter: local_adapter())

      assert_receive {:server_waiting, pid}
      send(pid, :release)
    end

    test "enforces Mint's header-parser limit before response materialization" do
      put_app_env(:lua_tool_http, max_response_header_bytes: 256)

      {_, port} =
        start_http_server!(fn conn, _opts ->
          conn
          |> Plug.Conn.put_resp_header("x-huge", String.duplicate("x", 2_000))
          |> Plug.Conn.send_resp(200, "not read")
        end)

      url = "http://api.example.com:#{port}/v1/items"

      assert {:error, "HTTP transport failed"} =
               request(%{"url" => url}, [rule(url)], %{}, adapter: local_adapter())
    end
  end

  defp rule(url \\ "https://api.example.com/v1/*", methods \\ ["GET"], secrets \\ []) do
    %{"url" => url, "methods" => methods, "secrets" => secrets}
  end

  defp request(params \\ %{}, rules \\ [rule()], secrets \\ %{}, opts \\ []) do
    opts = Keyword.merge([resolver: fn _ -> {:ok, [@public]} end, adapter: &plug_adapter/1], opts)
    Http.request(Map.merge(%{"url" => @url}, params), rules, secrets, opts)
  end

  defp plug_adapter(req) do
    Req.Plug.run(%{req | options: Map.put(req.options, :plug, {Req.Test, __MODULE__})})
  end

  defp local_adapter do
    fn req ->
      assert req.private.ic_lua_http_address == @public
      assert req.options.connect_options[:hostname] == req.url.host

      HttpTransport.run(%{
        req
        | private: Map.put(req.private, :ic_lua_http_address, {127, 0, 0, 1})
      })
    end
  end

  defp ip(text) do
    {:ok, address} = :inet.parse_strict_address(String.to_charlist(text))
    address
  end

  defp assert_blocked_address(text) do
    assert {:error, "HTTP destination is not a public address"} =
             request(%{}, [rule()], %{}, resolver: fn _ -> {:ok, [ip(text)]} end)

    host = if String.contains?(text, ":"), do: "[#{text}]", else: text
    url = "https://#{host}/v1/items"

    assert {:error, "HTTP destination is not a public address"} =
             request(%{"url" => url}, [rule(url)], %{},
               resolver: fn _ -> flunk("literal IP resolved") end
             )
  end
end
