defmodule IntellectualClub.Llm.Providers.Responses.CodexHeadersTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias IntellectualClub.Llm.Providers.Responses.{Api, CodexHeaders, ModelDiscovery}

  @base_url "https://chatgpt.com/backend-api/codex"

  test "selects the token account for Codex HTTP, WebSocket and model requests" do
    token = token(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "account-123"}})
    headers = [{"authorization", "Bearer " <> token}]

    for url <- [
          @base_url,
          @base_url <> "/responses",
          @base_url <> "/models?client_version=1.0.0",
          "wss://chatgpt.com/backend-api/codex/responses"
        ] do
      assert CodexHeaders.put_account_id(headers, url, token) ==
               headers ++ [{"chatgpt-account-id", "account-123"}]
    end
  end

  test "does not send account metadata to other providers or unencrypted endpoints" do
    token = token(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "account-123"}})
    headers = [{"authorization", "Bearer " <> token}]

    for url <- [
          "https://api.openai.com/v1/responses",
          "https://openrouter.ai/api/v1/responses",
          "https://chatgpt.com.example.com/backend-api/codex/responses",
          "https://chatgpt.com/backend-api/codex-other/responses",
          "https://chatgpt.com/other",
          "http://chatgpt.com/backend-api/codex/responses",
          "ws://chatgpt.com/backend-api/codex/responses"
        ] do
      assert CodexHeaders.put_account_id(headers, url, token) == headers
    end
  end

  test "ignores API keys, malformed claims and unsafe account header values" do
    tokens = [nil, "sk-test-key", "header.!.signature", "header.bm90LWpzb24.signature"]

    tokens =
      tokens ++
        Enum.map([nil, [], %{}, %{"https://api.openai.com/auth" => "unexpected"}], &token/1) ++
        Enum.map([nil, 123, [], %{}, "", " ", "bad\r\nheader", "bad\0header", "аккаунт"], fn id ->
          token(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => id}})
        end)

    for token <- tokens do
      assert CodexHeaders.put_account_id([{"accept", "application/json"}], @base_url, token) ==
               [{"accept", "application/json"}]
    end
  end

  test "HTTP generation and model discovery select the account on the actual request" do
    token = token(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "account-123"}})
    previous_options = Req.default_options()
    on_exit(fn -> Req.default_options(previous_options) end)
    test_pid = self()

    Req.default_options(
      plug: fn conn ->
        send(
          test_pid,
          {:account_header, conn.request_path, get_req_header(conn, "chatgpt-account-id")}
        )

        case conn.request_path do
          "/backend-api/codex/responses" ->
            event = %{
              "type" => "response.completed",
              "response" => %{"id" => "resp_account", "status" => "completed", "output" => []}
            }

            send_resp(conn, 200, "data: " <> Jason.encode!(event) <> "\n\n")

          "/backend-api/codex/models" ->
            Req.Test.json(conn, %{"models" => [%{"slug" => "test-model"}]})
        end
      end
    )

    Api.stream_generate(
      %{
        base_url: @base_url,
        api_key: token,
        request_payload: %{"model" => "test-model", "input" => []}
      },
      &send(test_pid, &1)
    )

    assert_receive {:account_header, "/backend-api/codex/responses", ["account-123"]}
    assert_receive {:response_complete, _meta}

    assert {:ok, [%{id: "test-model"}]} =
             ModelDiscovery.list_models(%{
               base_url: @base_url,
               auth_method: "api_key",
               api_key: token
             })

    assert_receive {:account_header, "/backend-api/codex/models", ["account-123"]}
  end

  defp token(claims) do
    "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".signature"
  end
end
