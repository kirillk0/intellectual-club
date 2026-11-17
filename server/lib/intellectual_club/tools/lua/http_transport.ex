defmodule IntellectualClub.Tools.Lua.HttpTransport do
  @moduledoc false

  # Req's documented adapter contract allows a passive Mint connection without
  # global defaults, DNS re-resolution, dynamically named pools, or telemetry
  # carrying request credentials. Mint.HTTP.connect/4 documents :hostname as the
  # identity for Host, SNI, and certificate hostname verification independently
  # of the address tuple. TLS retains :verify_peer and Mint's CA/hostname checks.
  def run(request) do
    {adapter, private} = Map.pop(request.private, :ic_lua_http_adapter)
    request = %{request | private: private}
    if adapter, do: adapter.(request), else: connect(request)
  end

  defp connect(request) do
    scheme = if request.url.scheme == "https", do: :https, else: :http
    address = Map.fetch!(request.private, :ic_lua_http_address)

    case Mint.HTTP.connect(scheme, address, request.url.port, request.options.connect_options) do
      {:ok, connection} ->
        try do
          send_request(connection, request)
        after
          Mint.HTTP.close(connection)
        end

      {:error, _} ->
        failure(request)
    end
  end

  defp send_request(connection, request) do
    path = request.url.path || "/"
    target = if request.url.query, do: path <> "?" <> request.url.query, else: path
    method = request.method |> Atom.to_string() |> String.upcase()
    headers = for {name, values} <- request.headers, value <- values, do: {name, value}

    case Mint.HTTP.request(connection, method, target, headers, request.body) do
      {:ok, connection, ref} ->
        receive_response(connection, ref, {request, Req.Response.new()})

      {:error, _, _} ->
        failure(request)
    end
  end

  defp receive_response(connection, ref, {request, _} = acc) do
    case Mint.HTTP.recv(connection, 0, request.options.receive_timeout) do
      {:ok, connection, events} ->
        case consume(events, ref, acc) do
          {:cont, acc} -> receive_response(connection, ref, acc)
          {:halt, acc} -> acc
        end

      {:error, _, _, _} ->
        failure(request)
    end
  end

  defp consume([], _ref, acc), do: {:cont, acc}

  defp consume([event | rest], ref, {request, response} = acc) do
    result =
      case event do
        {:status, ^ref, status} ->
          {:cont, {request, %{response | status: status}}}

        {:headers, ^ref, headers} ->
          fields =
            Enum.reduce(headers, response.headers, fn {name, value}, fields ->
              Map.update(fields, name, [value], &(&1 ++ [value]))
            end)

          # Validate size and content encoding before accepting any body bytes,
          # including for HEAD, empty responses, and chunked trailers.
          request.into.({:data, ""}, {request, %{response | headers: fields}})

        {:data, ^ref, data} ->
          request.into.({:data, data}, acc)

        {:done, ^ref} ->
          {:halt, acc}

        _ ->
          {:halt, failure(request)}
      end

    case result do
      {:cont, acc} -> consume(rest, ref, acc)
      {:halt, acc} -> {:halt, acc}
    end
  end

  defp failure(request), do: {request, %Req.TransportError{reason: :closed}}
end
