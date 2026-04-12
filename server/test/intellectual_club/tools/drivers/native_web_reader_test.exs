defmodule IntellectualClub.Tools.Drivers.NativeWebReaderTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Tools.Drivers.NativeWebReader
  alias IntellectualClub.Tools.ToolInstance

  test "exposes fixed read_url and search_url functions" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    functions = NativeWebReader.fixed_functions(tool_instance)

    assert is_list(functions)
    assert Enum.any?(functions, fn spec -> Map.get(spec, "name") == "read_url" end)
    assert Enum.any?(functions, fn spec -> Map.get(spec, "name") == "search_url" end)
  end

  test "execute requires url for read_url" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    assert {:error, "Argument `url` is required."} =
             NativeWebReader.execute(tool_instance, "read_url", %{})
  end

  test "execute validates page argument for read_url" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    assert {:error, "Argument `page` must be a non-negative integer (1-based)."} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "https://example.com",
               "page" => -1
             })
  end

  test "execute requires regex for search_url" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    assert {:error, "Argument `regex` is required."} =
             NativeWebReader.execute(tool_instance, "search_url", %{
               "url" => "https://example.com"
             })
  end

  test "execute rejects unknown function" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    assert {:error, "Unknown function: unknown"} =
             NativeWebReader.execute(tool_instance, "unknown", %{})
  end

  test "read_url returns a valid utf-8 error when upstream body is not utf-8" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{type: "native-web-reader", config: %{}, secrets: %{}})

    body =
      <<"<html><body><h1> HTTP/1.1 ", 208, 194, 189, 168, 187, 225, 187, 176, 202, 167, 176, 220,
        "</h1></body></html>">>

    {:ok, server} = start_raw_http_server(500, "text/html", body)

    on_exit(fn -> stop_raw_http_server(server) end)

    assert {:error, message} =
             NativeWebReader.execute(tool_instance, "read_url", %{
               "url" => "http://127.0.0.1:#{server.port}/broken"
             })

    assert String.starts_with?(message, "HTTP error while fetching URL: 500.")
    assert String.valid?(message)
    assert message =~ "ÐÂ½¨»á»°Ê§°Ü"
  end

  defp create_tool_instance!(actor, attrs) when is_map(attrs) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          type: "native-web-reader",
          name: "Web Reader",
          config: %{},
          secrets: %{},
          max_output_tokens: 20_000
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!()
  end

  defp start_raw_http_server(status, content_type, body)
       when is_integer(status) and is_binary(content_type) and is_binary(body) do
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
end
