defmodule IntellectualClub.LlmCore.ResponsesApiTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias IntellectualClub.LlmCore.ResponsesApi

  @base_opts %{
    base_url: "http://127.0.0.1:9",
    api_key: "test-key",
    model_name: "gpt-4.1",
    timeout_ms: 200,
    connect_timeout_ms: 200
  }

  test "forces store=false and adds empty instructions when missing" do
    error =
      run_and_capture_error!(
        Map.put(@base_opts, :request_payload, %{
          "model" => "gpt-4.1",
          "input" => []
        })
      )

    assert error.raw_request["store"] == false
    assert error.raw_request["instructions"] == ""
  end

  test "preserves provided instructions while forcing store=false" do
    error =
      run_and_capture_error!(
        Map.put(@base_opts, :request_payload, %{
          "model" => "gpt-4.1",
          "input" => [],
          "instructions" => "You are a careful assistant.",
          "store" => true
        })
      )

    assert error.raw_request["store"] == false
    assert error.raw_request["instructions"] == "You are a careful assistant."
  end

  test "hydrates completed response output from stream items when terminal response omits it" do
    scripts = %{
      "/responses" => [
        {200,
         sse_chunks([
           %{
             "type" => "response.output_item.added",
             "output_index" => 0,
             "item" => %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "content" => []
             }
           },
           %{
             "type" => "response.output_text.done",
             "item_id" => "msg_1",
             "output_index" => 0,
             "content_index" => 0,
             "text" => "Checking."
           },
           %{
             "type" => "response.output_item.added",
             "output_index" => 1,
             "item" => %{
               "id" => "fc_1",
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "web__read_url",
               "arguments" => ""
             }
           },
           %{
             "type" => "response.function_call_arguments.done",
             "item_id" => "fc_1",
             "output_index" => 1,
             "arguments" => ~s({"url":"https://example.com"})
           },
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_1",
               "object" => "response",
               "model" => "gpt-4.1",
               "status" => "completed",
               "usage" => %{
                 "input_tokens" => 3,
                 "output_tokens" => 2
               }
             }
           }
         ])}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)
    parent = self()

    :ok =
      ResponsesApi.stream_generate(
        %{
          base_url: base_url,
          api_key: "test-key",
          model_name: "gpt-4.1",
          request_payload: %{
            "model" => "gpt-4.1",
            "input" => [],
            "instructions" => ""
          },
          timeout_ms: 1_000,
          connect_timeout_ms: 1_000
        },
        fn event ->
          send(parent, {:provider_event, event})
        end
      )

    assert_receive {:provider_event, {:response_complete, meta}}, 2_000

    assert meta.raw_response["output"] == [
             %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "Checking."
                 }
               ]
             },
             %{
               "id" => "fc_1",
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "web__read_url",
               "arguments" => ~s({"url":"https://example.com"})
             }
           ]
  end

  defp run_and_capture_error!(opts) when is_map(opts) do
    parent = self()

    :ok =
      ResponsesApi.stream_generate(opts, fn event ->
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
        {Bandit, plug: {__MODULE__.ScriptedSSEPlug, agent: agent}, scheme: :http, port: port}
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

  defmodule ScriptedSSEPlug do
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

      {response_chunks, status_code} =
        Agent.get_and_update(agent, fn state ->
          request_path = conn.request_path

          requests =
            Map.update(state.requests, request_path, [payload], fn existing ->
              existing ++ [payload]
            end)

          case Map.get(state.scripts, request_path, []) do
            [{code, chunks} | rest] ->
              {{chunks, code},
               %{state | scripts: Map.put(state.scripts, request_path, rest), requests: requests}}

            [] ->
              {{"No scripted response for #{request_path}", 500}, %{state | requests: requests}}
          end
        end)

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
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
