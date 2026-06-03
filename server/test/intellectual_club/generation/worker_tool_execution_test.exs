defmodule IntellectualClub.Generation.WorkerToolExecutionTest do
  use ExUnit.Case, async: false

  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.Tools.RateLimiter
  alias IntellectualClub.Tools.ToolInstance

  defmodule ConcurrentMcpPlug do
    import Plug.Conn

    @tool_call_release_timeout_ms 10_000

    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)

      case payload["method"] do
        "initialize" ->
          response = %{
            "jsonrpc" => "2.0",
            "id" => payload["id"],
            "result" => %{"capabilities" => %{}}
          }

          conn
          |> put_resp_header("mcp-session-id", "test-session")
          |> put_resp_content_type("text/event-stream")
          |> send_resp(200, sse(response))

        "tools/call" ->
          tool_name = get_in(payload, ["params", "name"])
          send(test_pid, {:tool_call_entered, self(), tool_name})

          receive do
            :release_tool_call -> :ok
          after
            @tool_call_release_timeout_ms -> send(test_pid, {:tool_call_wait_timeout, tool_name})
          end

          response = %{
            "jsonrpc" => "2.0",
            "id" => payload["id"],
            "result" => %{
              "content" => [%{"type" => "text", "text" => "result #{tool_name}"}]
            }
          }

          conn
          |> put_resp_content_type("text/event-stream")
          |> send_resp(200, sse(response))

        other ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(500, "Unsupported method: #{inspect(other)}")
      end
    end

    defp sse(object), do: "data: " <> Jason.encode!(object) <> "\n\n"
  end

  setup do
    RateLimiter.reset()
    :ok
  end

  test "execute_tool_calls runs a batch concurrently and preserves result order" do
    server_url = start_mcp_server!()

    tool = %ToolInstance{
      id: System.unique_integer([:positive, :monotonic]),
      type: "mcp-http",
      config: %{"server_url" => server_url},
      secrets: %{},
      max_output_tokens: 20_000
    }

    calls = [
      %{
        call_id: "call_second",
        name: "web__second",
        args: %{},
        raw: %{"id" => "call_second"}
      },
      %{
        call_id: "call_first",
        name: "web__first",
        args: %{},
        raw: %{"id" => "call_first"}
      }
    ]

    task = Task.async(fn -> Worker.execute_tool_calls(calls, %{"web" => tool}, nil) end)

    entered =
      Enum.map(1..2, fn _ ->
        receive do
          {:tool_call_entered, pid, tool_name} -> {pid, tool_name}
          {:tool_call_wait_timeout, tool_name} -> flunk("Tool call timed out: #{tool_name}")
        after
          5_000 -> flunk("Expected both tool calls to enter execution concurrently")
        end
      end)

    assert entered |> Enum.map(&elem(&1, 1)) |> Enum.sort() == ["first", "second"]

    Enum.each(entered, fn {pid, _tool_name} -> send(pid, :release_tool_call) end)

    results = Task.await(task, 5_000)

    assert Enum.map(results, & &1.call_id) == ["call_second", "call_first"]
    assert Enum.map(results, & &1.text) == ["result second", "result first"]
  end

  defp start_mcp_server! do
    port = free_port()

    start_supervised!(
      {Bandit, plug: {ConcurrentMcpPlug, test_pid: self()}, scheme: :http, port: port}
    )

    wait_for_server!(port)

    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_for_server!(port) when is_integer(port) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_for_server!(port, deadline)
  end

  defp do_wait_for_server!(port, deadline) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 50) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("MCP server did not start before timeout")
        else
          Process.sleep(5)
          do_wait_for_server!(port, deadline)
        end
    end
  end
end
