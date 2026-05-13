defmodule IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ChatCompletionTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ChatCompletion

  @request_payload %{
    "model" => "deepseek/deepseek-v4-pro",
    "messages" => [%{"role" => "user", "content" => "Hello"}]
  }

  test "sends OpenRouter app attribution headers" do
    scripts = %{
      "/chat/completions" => [
        {200, sse_chunks([%{"choices" => [%{"delta" => %{"content" => "Hi"}}]}])}
      ]
    }

    {base_url, agent} = start_scripted_server!(scripts)

    :ok =
      ChatCompletion.stream_generate(
        %{
          base_url: base_url,
          api_key: "test-key",
          request_payload: @request_payload,
          timeout_ms: 1_000,
          connect_timeout_ms: 1_000
        },
        fn _event -> :ok end
      )

    [request] = recorded_requests(agent, "/chat/completions")

    assert {"http-referer", "https://github.com/kirillk0/intellectual-club"} in request.headers
    assert {"x-openrouter-title", "Intellectual Club"} in request.headers
  end

  test "uses metadata raw text for generic streamed provider errors" do
    scripts = %{
      "/chat/completions" => [
        {200,
         sse_chunks([
           %{
             "error" => %{
               "code" => 429,
               "message" => "Provider returned error",
               "metadata" => %{
                 "raw" => "deepseek/deepseek-v4-pro is temporarily rate-limited upstream."
               }
             }
           }
         ])}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)

    error =
      run_and_capture_error!(%{
        base_url: base_url,
        api_key: "test-key",
        request_payload: @request_payload,
        timeout_ms: 1_000,
        connect_timeout_ms: 1_000
      })

    assert error.status_code == 429
    assert error.retryable == true
    assert error.error_text == "deepseek/deepseek-v4-pro is temporarily rate-limited upstream."
  end

  test "uses metadata raw text for generic HTTP provider errors" do
    scripts = %{
      "/chat/completions" => [
        {429,
         [
           Jason.encode!(%{
             "error" => %{
               "code" => 429,
               "message" => "Provider returned error",
               "metadata" => %{
                 "raw" => "Provider quota is temporarily exhausted."
               }
             }
           })
         ]}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)

    error =
      run_and_capture_error!(%{
        base_url: base_url,
        api_key: "test-key",
        request_payload: @request_payload,
        timeout_ms: 1_000,
        connect_timeout_ms: 1_000
      })

    assert error.status_code == 429
    assert error.retryable == true
    assert error.error_text == "Provider quota is temporarily exhausted."
  end

  defp run_and_capture_error!(opts) when is_map(opts) do
    parent = self()

    :ok =
      ChatCompletion.stream_generate(opts, fn event ->
        send(parent, {:provider_event, event})
      end)

    assert_receive {:provider_event, {:response_error, error}}, 2_000
    error
  end

  defp start_scripted_server!(scripts) when is_map(scripts) do
    {:ok, agent} =
      start_supervised(
        {Agent,
         fn ->
           %{
             scripts: scripts,
             requests: %{}
           }
         end}
      )

    port = free_port()

    {:ok, _server} =
      start_supervised(
        {Bandit, plug: {__MODULE__.ScriptedPlug, agent: agent}, scheme: :http, port: port}
      )

    {"http://127.0.0.1:#{port}", agent}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp sse_chunks(objects) when is_list(objects) do
    Enum.map(objects, fn object -> "data: " <> Jason.encode!(object) <> "\n\n" end) ++
      ["data: [DONE]\n\n"]
  end

  defp recorded_requests(agent, path) when is_pid(agent) and is_binary(path) do
    Agent.get(agent, fn state -> Map.get(state.requests, path, []) end)
  end

  defmodule ScriptedPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, body, conn} = read_body(conn)

      payload =
        case Jason.decode(body) do
          {:ok, %{} = decoded} -> decoded
          _other -> %{"raw_body" => body}
        end

      request = %{
        headers: conn.req_headers,
        payload: payload
      }

      {response_chunks, status_code} =
        Agent.get_and_update(agent, fn state ->
          request_path = conn.request_path

          requests =
            Map.update(state.requests, request_path, [request], fn existing ->
              existing ++ [request]
            end)

          case Map.get(state.scripts, request_path, []) do
            [{code, chunks} | rest] ->
              {{chunks, code},
               %{state | scripts: Map.put(state.scripts, request_path, rest), requests: requests}}

            [] ->
              {{"No scripted response for #{request_path}", 500}, %{state | requests: requests}}
          end
        end)

      content_type =
        if status_code >= 400 do
          "application/json"
        else
          "text/event-stream"
        end

      conn =
        conn
        |> put_resp_content_type(content_type)
        |> send_chunked(status_code)

      Enum.reduce_while(List.wrap(response_chunks), conn, fn chunk, conn ->
        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end
  end
end
