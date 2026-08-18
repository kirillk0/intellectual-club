defmodule IntellectualClub.Llm.Providers.Responses.EndpointTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.Responses.Endpoint

  test "uses HTTP by default" do
    assert {:ok, endpoint} = Endpoint.resolve(nil)

    assert endpoint.transport == :http
    assert endpoint.http_base_url == "https://api.openai.com/v1"
    assert endpoint.websocket_base_url == "wss://api.openai.com/v1"
  end

  test "normalizes HTTP and WebSocket schemes" do
    assert {:ok, http} = Endpoint.resolve("http://example.com/api/")
    assert http.transport == :http
    assert http.http_base_url == "http://example.com/api"
    assert http.websocket_base_url == "ws://example.com/api"

    assert {:ok, https} = Endpoint.resolve("https://example.com/api")
    assert https.transport == :http
    assert https.http_base_url == "https://example.com/api"
    assert https.websocket_base_url == "wss://example.com/api"

    assert {:ok, ws} = Endpoint.resolve("ws://example.com/api")
    assert ws.transport == :websocket
    assert ws.http_base_url == "http://example.com/api"
    assert ws.websocket_base_url == "ws://example.com/api"

    assert {:ok, wss} = Endpoint.resolve("wss://example.com/api/")
    assert wss.transport == :websocket
    assert wss.http_base_url == "https://example.com/api"
    assert wss.websocket_base_url == "wss://example.com/api"
  end

  test "legacy mode forces WebSocket transport for an HTTPS URL" do
    assert {:ok, endpoint} =
             Endpoint.resolve("https://api.openai.com/v1", force_websocket?: true)

    assert endpoint.transport == :websocket
    assert endpoint.http_base_url == "https://api.openai.com/v1"
    assert endpoint.websocket_base_url == "wss://api.openai.com/v1"
  end

  test "rejects unsupported or hostless URLs" do
    assert {:error, :invalid_base_url} = Endpoint.resolve("ftp://example.com/v1")
    assert {:error, :invalid_base_url} = Endpoint.resolve("wss:///v1")
  end
end
