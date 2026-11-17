defmodule IntellectualClub.Tools.Lua.Http do
  @moduledoc """
  Manifest-scoped HTTP for Lua tools. This module performs no database work.

  The caller must preload tool-attached secrets with the executing actor, and
  enforce the invocation's HTTP-call count and total execution deadline. Only
  string-keyed JSON request/rule maps are accepted. One matching rule must allow
  all requested secret names; permission rules are not combined to widen access.

  `request/4` returns string keys, with lowercase response header names mapped to
  lists of values. JSON is decoded when possible, independently of content type.
  Secrets are redacted from text, header names/values, and decoded JSON (including
  keys). JSON bodies with redacted values are re-encoded to remove escaped secret
  representations as well. This is exact-value redaction, not protection against an upstream service
  intentionally encoding or transforming credentials.

  Only public HTTP(S), HTTP/1, UTF-8 response bodies, and identity content encoding
  are supported. Ambiguous paths (dot segments, encoded separators, nested percent
  encoding, backslashes, repeated slashes, and path parameters) are rejected rather
  than normalized differently by a proxy or origin. `*` matches any path substring,
  including `/`. Rules cannot contain a query, fragment, or userinfo.

  Server policy is a keyword list at `:intellectual_club, :lua_tool_http`:
  `:connect_timeout_ms` (3_000), `:receive_timeout_ms` (5_000),
  `:request_timeout_ms` (10_000, including DNS), `:max_request_body_bytes`
  (262_144), `:max_response_body_bytes` (1_048_576),
  `:max_request_header_bytes` (16_384), `:max_response_header_bytes` (32_768),
  `:max_headers` (64), and `:max_url_bytes` (8_192). Values must be positive integers.
  No setting enables internal networks or disables TLS verification.

  The only trusted, Elixir-only options are `:resolver`, a function receiving the
  hostname and returning `{:ok, [ip_tuple]}` or an error, and `:adapter`, a Req
  adapter function. Never derive these options from Lua or manifest parameters.
  Even a substituted resolver is subject to the public-address policy. Adapters
  receive the checked IP in `request.private.ic_lua_http_address` and must honor
  `request.into` streaming; replacing the adapter is a trusted test boundary.
  """

  import Bitwise

  alias IntellectualClub.Tools.Lua.{Codec, HttpTransport, Limits}

  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "OPTIONS" => :options
  }
  @request_keys ~w(method url headers query json body bearer_secret secret_headers)
  @rule_keys ~w(methods url secrets)
  @blocked_headers ~w(host proxy connection keep-alive te trailer transfer-encoding upgrade
                      content-length expect accept-encoding content-encoding forwarded via
                      x-http-method x-http-method-override x-method-override x-original-url
                      x-rewrite-url)
  @defaults [
    connect_timeout_ms: 3_000,
    receive_timeout_ms: 5_000,
    request_timeout_ms: 10_000,
    max_request_body_bytes: 262_144,
    max_response_body_bytes: 1_048_576,
    max_request_header_bytes: 16_384,
    max_response_header_bytes: 32_768,
    max_headers: 64,
    max_url_bytes: 8_192
  ]
  @ipv4_denied [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4},
    {{168, 63, 129, 16}, 32}
  ]
  # Only global unicast is eligible; these special-use subranges are still denied.
  @ipv6_denied [
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20}
  ]

  @spec validate_permissions(term()) :: :ok | {:error, String.t()}
  def validate_permissions(rules) do
    safely(fn ->
      case compile_rules(rules) do
        {:ok, _} -> :ok
        error -> error
      end
    end)
  end

  @spec request(map(), list(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def request(params, rules, authorized_secret_values, opts \\ []) do
    result =
      safely(fn ->
        with {:ok, limits} <- limits(),
             :ok <- trusted_options(opts) do
          # The linked worker owns its sockets. Cancellation of the parent or this
          # deadline also closes in-flight connections, including during DNS/TLS.
          task =
            Task.async(fn ->
              Process.flag(:max_heap_size, Limits.heap_limit())
              safely(fn -> run(params, rules, authorized_secret_values, opts, limits) end)
            end)

          case Task.yield(task, limits.request_timeout_ms) do
            {:ok, result} ->
              result

            _ ->
              Task.shutdown(task, :brutal_kill)
              {:error, "HTTP request deadline exceeded"}
          end
        end
      end)

    case result do
      {:error, message} -> {:error, redact(message, redactor(authorized_secret_values))}
      other -> other
    end
  end

  defp run(params, rules, secrets, opts, limits) do
    with true <- plain_map?(params) and known_keys?(params, @request_keys),
         true <-
           plain_map?(secrets) and
             Enum.all?(secrets, fn {name, value} ->
               secret_name?(name) and is_binary(value) and String.valid?(value)
             end),
         {:ok, rules} <- compile_rules(rules),
         {:ok, method} <- method(Map.get(params, "method", "GET")),
         {:ok, uri, path} <- url(params["url"], :request, limits.max_url_bytes),
         {:ok, uri} <- query(uri, Map.get(params, "query", %{}), limits),
         {:ok, headers} <- headers(Map.get(params, "headers", %{})),
         {:ok, secret_headers} <- headers(Map.get(params, "secret_headers", %{})),
         {:ok, names} <- secret_names(params["bearer_secret"], secret_headers),
         :ok <- permitted(rules, method, uri, path, names),
         {:ok, headers} <-
           inject_secrets(headers, secret_headers, params["bearer_secret"], secrets),
         {:ok, body, headers} <- body(params, headers, limits),
         headers = wire_headers(headers, uri, body),
         :ok <- header_budget(headers, limits.max_request_header_bytes, limits.max_headers),
         {:ok, address} <- resolve(uri.host, Keyword.get(opts, :resolver, &resolve_host/1)),
         {:ok, response} <- send_request(method, uri, headers, body, address, opts, limits) do
      response(response, secrets, limits)
    else
      false -> {:error, "Invalid HTTP request parameters"}
      {:error, _} = error -> error
    end
  end

  defp compile_rules(rules) when is_list(rules) and length(rules) <= 128 do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, acc} ->
      with true <- plain_map?(rule) and known_keys?(rule, @rule_keys),
           methods when is_list(methods) and methods != [] <- rule["methods"],
           true <-
             length(methods) <= map_size(@methods) and
               Enum.all?(methods, &Map.has_key?(@methods, &1)),
           secrets = Map.get(rule, "secrets", []),
           true <-
             is_list(secrets) and length(secrets) <= 64 and Enum.all?(secrets, &secret_name?/1),
           {:ok, uri, path} <- url(rule["url"], :rule, 8_192) do
        pattern = path |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)

        compiled = %{
          methods: methods,
          origin: origin(uri),
          path: Regex.compile!("\\A" <> pattern <> "\\z"),
          secrets: secrets
        }

        {:cont, {:ok, [compiled | acc]}}
      else
        _ -> {:halt, {:error, "Invalid HTTP permission rule"}}
      end
    end)
  end

  defp compile_rules(_), do: {:error, "Invalid HTTP permission rules"}

  defp method(method) when is_binary(method) do
    method = String.upcase(method)

    if Map.has_key?(@methods, method),
      do: {:ok, method},
      else: {:error, "Unsupported HTTP method"}
  end

  defp method(_), do: {:error, "Invalid HTTP method"}

  defp url(value, kind, max_bytes) when is_binary(value) do
    with true <- byte_size(value) <= max_bytes and Regex.match?(~r/\A[\x21-\x7E]+\z/, value),
         false <- String.contains?(value, "\\"),
         {:ok, uri} <- URI.new(value),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host),
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- kind != :rule or is_nil(uri.query),
         {:ok, host} <- hostname(uri.host),
         true <- valid_authority?(value, uri),
         {:ok, path} <- path(uri.path || "/", kind) do
      {:ok, %{uri | host: host, path: uri.path || "/"}, path}
    else
      _ -> {:error, "Invalid or unsafe HTTP URL"}
    end
  end

  defp url(_, _, _), do: {:error, "Invalid HTTP URL"}

  defp valid_authority?(value, uri) do
    [_, rest] = String.split(value, "://", parts: 2)
    raw = rest |> String.split(["/", "?", "#"], parts: 2) |> hd()
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    raw == host or raw == "#{host}:#{uri.port}"
  end

  defp hostname(host) do
    host = String.downcase(host)

    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, address |> :inet.ntoa() |> to_string()}

      _ ->
        if byte_size(host) <= 253 and
             Regex.match?(
               ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/,
               host
             ) and
             not Regex.match?(~r/\A[0-9.]+\z/, host) and
             not Regex.match?(~r/\A(?:0x[0-9a-f]+)(?:\.|\z)/, host) do
          {:ok, host}
        else
          {:error, "Invalid HTTP hostname"}
        end
    end
  end

  defp path(raw, kind) do
    decoded = URI.decode(raw)

    if String.starts_with?(raw, "/") and String.valid?(decoded) and
         not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, raw) and
         not Regex.match?(~r/%(?:2f|5c)/i, raw) and
         not Regex.match?(~r/[\x00-\x20\x7F\\%?#;\[\]{}]/, decoded) and
         not String.contains?(decoded, "//") and
         not Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."])) and
         (kind != :rule or not String.contains?(raw, ["%2a", "%2A"])) do
      {:ok, decoded}
    else
      {:error, "Unsafe HTTP path"}
    end
  end

  defp query(uri, query, limits) do
    if plain_map?(query) and Enum.all?(query, fn {k, v} -> is_binary(k) and query_value?(v) end) do
      encoded = URI.encode_query(query)
      combined = Enum.reject([uri.query, encoded], &(&1 in [nil, ""])) |> Enum.join("&")
      uri = %{uri | query: if(combined == "", do: nil, else: combined)}

      if byte_size(URI.to_string(uri)) <= limits.max_url_bytes,
        do: {:ok, uri},
        else: {:error, "HTTP URL is too large"}
    else
      {:error, "Invalid HTTP query parameters"}
    end
  end

  defp query_value?(v), do: is_binary(v) or is_number(v) or is_boolean(v)

  defp headers(map) do
    if plain_map?(map) do
      Enum.reduce_while(map, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
        if header_name?(name) and header_value?(value) do
          name = String.downcase(name)

          if name in @blocked_headers or String.starts_with?(name, ["proxy-", "x-forwarded-"]) or
               Map.has_key?(acc, name) do
            {:halt, {:error, "Forbidden or duplicate HTTP header"}}
          else
            {:cont, {:ok, Map.put(acc, name, value)}}
          end
        else
          {:halt, {:error, "Invalid HTTP header"}}
        end
      end)
    else
      {:error, "Invalid HTTP headers"}
    end
  end

  defp header_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..128 and
        Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name)

  defp header_value?(value),
    do: is_binary(value) and String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/, value)

  defp secret_name?(name),
    do: header_value?(name) and byte_size(name) in 1..256 and String.trim(name) == name

  defp secret_names(bearer, headers) do
    names = Map.values(headers) ++ if(is_nil(bearer), do: [], else: [bearer])

    if Enum.all?(names, &secret_name?/1),
      do: {:ok, Enum.uniq(names)},
      else: {:error, "Invalid HTTP secret reference"}
  end

  defp permitted(rules, method, uri, path, names) do
    if Enum.any?(rules, fn rule ->
         method in rule.methods and origin(uri) == rule.origin and Regex.match?(rule.path, path) and
           Enum.all?(names, &(&1 in rule.secrets))
       end) do
      :ok
    else
      {:error, "HTTP request is not permitted"}
    end
  end

  defp inject_secrets(headers, references, bearer, secrets) do
    if bearer && Map.has_key?(references, "authorization") do
      {:error, "Conflicting HTTP authorization headers"}
    else
      references = if bearer, do: Map.put(references, "authorization", bearer), else: references

      Enum.reduce_while(references, {:ok, headers}, fn {header, name}, {:ok, acc} ->
        value = Map.get(secrets, name)

        cond do
          Map.has_key?(acc, header) ->
            {:halt, {:error, "Conflicting HTTP secret headers"}}

          not header_value?(value) or value == "" ->
            {:halt, {:error, "HTTP secret is unavailable or invalid"}}

          true ->
            value = if bearer && header == "authorization", do: "Bearer " <> value, else: value
            {:cont, {:ok, Map.put(acc, header, value)}}
        end
      end)
    end
  end

  defp body(params, headers, limits) do
    cond do
      Map.has_key?(params, "json") and Map.has_key?(params, "body") ->
        {:error, "HTTP json and body are mutually exclusive"}

      Map.has_key?(params, "json") ->
        case Jason.encode(params["json"]) do
          {:ok, body} ->
            bounded_body(body, Map.put_new(headers, "content-type", "application/json"), limits)

          _ ->
            {:error, "Invalid HTTP JSON body"}
        end

      Map.has_key?(params, "body") ->
        bounded_body(params["body"], headers, limits)

      true ->
        {:ok, nil, headers}
    end
  end

  defp bounded_body(body, headers, limits) when is_binary(body) do
    cond do
      byte_size(body) > limits.max_request_body_bytes ->
        {:error, "HTTP request body is too large"}

      not String.valid?(body) ->
        {:error, "HTTP request body must be UTF-8 text"}

      true ->
        {:ok, body, headers}
    end
  end

  defp bounded_body(_, _, _), do: {:error, "Invalid HTTP request body"}

  defp wire_headers(headers, uri, body) do
    headers =
      headers
      |> Map.put("host", authority(uri))
      |> Map.put("accept-encoding", "identity")
      |> Map.put_new("user-agent", "intellectual-club-lua-http")

    if is_binary(body),
      do: Map.put(headers, "content-length", Integer.to_string(byte_size(body))),
      else: headers
  end

  defp header_budget(headers, max_bytes, max_count) do
    {bytes, count} =
      Enum.reduce(headers, {0, 0}, fn {name, values}, {bytes, count} ->
        Enum.reduce(List.wrap(values), {bytes, count}, fn value, {bytes, count} ->
          {bytes + byte_size(name) + byte_size(value) + 4, count + 1}
        end)
      end)

    if bytes <= max_bytes and count <= max_count,
      do: :ok,
      else: {:error, "HTTP headers exceed the limit"}
  end

  defp resolve(host, resolver) do
    resolved =
      case :inet.parse_strict_address(String.to_charlist(host)) do
        {:ok, address} -> {:ok, [address]}
        _ -> resolver.(host)
      end

    case resolved do
      {:ok, addresses} when is_list(addresses) and addresses != [] and length(addresses) <= 64 ->
        if Enum.all?(addresses, &public_address?/1),
          do: {:ok, hd(addresses)},
          else: {:error, "HTTP destination is not a public address"}

      _ ->
        {:error, "HTTP DNS resolution failed"}
    end
  end

  defp resolve_host(host) do
    results = Enum.map([:inet, :inet6], &:inet.getaddrs(String.to_charlist(host), &1))

    # An inconclusive family lookup must not conceal an unsafe address.
    if Enum.any?(results, fn result ->
         match?({:error, reason} when reason not in [:nxdomain, :eafnosupport], result)
       end) do
      {:error, :dns}
    else
      {:ok,
       Enum.flat_map(results, fn
         {:ok, addresses} -> addresses
         _ -> []
       end)}
    end
  end

  defp public_address?(address) when is_tuple(address) and tuple_size(address) == 4 do
    valid_address?(address, 255) and not Enum.any?(@ipv4_denied, &in_subnet?(address, &1, 8))
  end

  defp public_address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    valid_address?(address, 65_535) and
      in_subnet?(address, {{0x2000, 0, 0, 0, 0, 0, 0, 0}, 3}, 16) and
      not Enum.any?(@ipv6_denied, &in_subnet?(address, &1, 16))
  end

  defp public_address?(_), do: false

  defp valid_address?(address, max),
    do: address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= max))

  defp in_subnet?(address, {network, prefix}, bits) do
    shift = tuple_size(address) * bits - prefix
    bsr(address_integer(address, bits), shift) == bsr(address_integer(network, bits), shift)
  end

  defp address_integer(address, bits),
    do: address |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> bsl(acc, bits) + part end)

  defp origin(uri), do: {uri.scheme, uri.host, uri.port}

  defp authority(uri) do
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    if uri.port == URI.default_port(uri.scheme), do: host, else: "#{host}:#{uri.port}"
  end

  defp send_request(method, uri, headers, body, address, opts, limits) do
    transport_opts = [
      timeout: limits.connect_timeout_ms,
      send_timeout: limits.connect_timeout_ms,
      inet6: tuple_size(address) == 8
    ]

    transport_opts =
      if uri.scheme == "https", do: [verify: :verify_peer] ++ transport_opts, else: transport_opts

    # Req.Request.new/1 intentionally bypasses global Req defaults/plugins.
    # The empty pipeline cannot redirect, retry, decompress, or add credentials.
    request =
      Req.Request.new(
        method: Map.fetch!(@methods, method),
        url: uri,
        headers: headers,
        body: body,
        adapter: HttpTransport,
        options: [
          redirect: false,
          retry: false,
          raw: true,
          compressed: false,
          decode_body: false,
          receive_timeout: limits.receive_timeout_ms,
          request_timeout: limits.request_timeout_ms,
          connect_options: [
            hostname: uri.host,
            protocols: [:http1],
            mode: :passive,
            log: false,
            max_header_list_size: limits.max_response_header_bytes,
            transport_opts: transport_opts
          ]
        ]
      )

    request = %{
      request
      | into: stream(limits),
        private: %{
          ic_lua_http_address: address,
          ic_lua_http_adapter: Keyword.get(opts, :adapter)
        }
    }

    case Req.request(request) do
      {:ok, response} -> {:ok, response}
      _ -> {:error, "HTTP transport failed"}
    end
  end

  defp stream(limits) do
    fn {:data, chunk}, {request, response} ->
      size = Map.get(response.private, :ic_lua_http_bytes, 0) + byte_size(chunk)

      with :ok <- response_headers(response, limits),
           true <- size <= limits.max_response_body_bytes do
        private = Map.put(response.private, :ic_lua_http_bytes, size)
        chunks = Map.get(private, :ic_lua_http_chunks, [])

        private =
          Map.put(
            private,
            :ic_lua_http_chunks,
            if(chunk == "", do: chunks, else: [chunk | chunks])
          )

        {:cont, {request, %{response | private: private}}}
      else
        false -> halt_stream(request, response, "HTTP response body is too large")
        {:error, message} -> halt_stream(request, response, message)
      end
    end
  end

  defp halt_stream(request, response, message) do
    private = %{ic_lua_http_error: message}
    {:halt, {request, %{response | private: private, body: ""}}}
  end

  defp response_headers(response, limits) do
    headers = response.headers
    encodings = Map.get(headers, "content-encoding", [])
    lengths = Map.get(headers, "content-length", [])

    with true <-
           Enum.all?(headers, fn {name, values} ->
             header_name?(name) and Enum.all?(values, &header_value?/1)
           end),
         :ok <- header_budget(headers, limits.max_response_header_bytes, limits.max_headers),
         true <- Enum.all?(encodings, &(String.downcase(String.trim(&1)) == "identity")),
         true <-
           Enum.all?(lengths, fn value ->
             case Integer.parse(value) do
               {size, ""} -> size >= 0 and size <= limits.max_response_body_bytes
               _ -> false
             end
           end) do
      :ok
    else
      false -> {:error, "Unsupported HTTP encoding or response size"}
      {:error, _} = error -> error
    end
  end

  defp response(response, secrets, limits) do
    with nil <- response.private[:ic_lua_http_error],
         true <- is_integer(response.status) and response.status in 200..599,
         :ok <- response_headers(response, limits) do
      body =
        response.private
        |> Map.get(:ic_lua_http_chunks, [])
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      if String.valid?(body) do
        redactor = redactor(secrets)

        {body, json} =
          case Jason.decode(body) do
            {:ok, decoded} ->
              Codec.validate!(decoded, limits.max_response_body_bytes)
              json = redact(decoded, redactor)
              body = if json == decoded, do: body, else: Jason.encode!(json)
              {body, json}

            _ ->
              {body, nil}
          end

        {:ok,
         %{
           "status" => response.status,
           "headers" => redact(response.headers, redactor),
           "body" => redact(body, redactor),
           "json" => json
         }}
      else
        {:error, "HTTP response body is not UTF-8 text"}
      end
    else
      error when is_binary(error) -> {:error, error}
      false -> {:error, "Unsupported HTTP response status"}
      {:error, _} = error -> error
    end
  end

  defp redactor(secrets) when is_map(secrets) do
    values =
      secrets
      |> Map.values()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort_by(&byte_size/1, :desc)

    if values == [],
      do: nil,
      else:
        {:binary.compile_pattern(values),
         if(String.contains?("[REDACTED]", values), do: "", else: "[REDACTED]")}
  end

  defp redactor(_), do: nil
  defp redact(value, nil), do: value

  defp redact(value, {pattern, marker}) when is_binary(value) do
    redacted = String.replace(value, pattern, marker)
    # Redaction must not create another secret across replacement boundaries.
    if :binary.match(redacted, pattern) == :nomatch, do: redacted, else: marker
  end

  defp redact(map, redactor) when is_map(map),
    do: Map.new(map, fn {k, v} -> {redact(k, redactor), redact(v, redactor)} end)

  defp redact(list, redactor) when is_list(list), do: Enum.map(list, &redact(&1, redactor))

  defp redact(value, redactor) do
    encoded = Jason.encode!(value)
    redacted = redact(encoded, redactor)
    if encoded == redacted, do: value, else: redacted
  end

  defp limits do
    configured = Application.get_env(:intellectual_club, :lua_tool_http, [])

    if Keyword.keyword?(configured) and
         Enum.all?(configured, fn {key, value} ->
           Keyword.has_key?(@defaults, key) and is_integer(value) and value > 0
         end) do
      {:ok, Map.new(Keyword.merge(@defaults, configured))}
    else
      {:error, "Invalid HTTP server policy"}
    end
  end

  defp trusted_options(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {key, value} ->
           key in [:resolver, :adapter] and is_function(value, 1)
         end), do: :ok, else: {:error, "Invalid trusted HTTP options"}
  end

  defp plain_map?(map), do: is_map(map) and not is_struct(map)
  defp known_keys?(map, allowed), do: Enum.all?(Map.keys(map), &(&1 in allowed))

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, "HTTP request failed"}
  catch
    _, _ -> {:error, "HTTP request failed"}
  end
end
