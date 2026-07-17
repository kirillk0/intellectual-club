defmodule IntellectualClubWeb.EndpointTest do
  use ExUnit.Case, async: true

  alias IntellectualClubWeb.Endpoint

  test "uses debug logging for noisy requests before a response is sent" do
    assert Endpoint.request_log_level(conn("/api/bff/chat-messages/2960/poll")) == :debug
    assert Endpoint.request_log_level(conn("/api/outlet/poll/")) == :debug
    assert Endpoint.request_log_level(conn("/api/outlet/pair/poll/")) == :debug
    assert Endpoint.request_log_level(conn("/api/bff/chat-list/idle-state")) == :debug
    assert Endpoint.request_log_level(conn("/api/bff/chat-state/131/idle-state")) == :debug
  end

  test "uses debug logging only for successful poll responses" do
    assert Endpoint.request_log_level(conn("/api/outlet/poll/", 200)) == :debug
    assert Endpoint.request_log_level(conn("/api/outlet/poll/", 400)) == :info
    assert Endpoint.request_log_level(conn("/api/outlet/poll/", 500)) == :info
  end

  test "uses debug logging only for unchanged idle state responses" do
    assert Endpoint.request_log_level(conn("/api/bff/chat-list/idle-state", 204)) == :debug
    assert Endpoint.request_log_level(conn("/api/bff/chat-state/131/idle-state", 204)) == :debug
    assert Endpoint.request_log_level(conn("/api/bff/chat-state/131/idle-state", 200)) == :info
    assert Endpoint.request_log_level(conn("/api/bff/chat-state/131/idle-state", 404)) == :info
    assert Endpoint.request_log_level(conn("/api/bff/chat-state/131/idle-state", 500)) == :info
  end

  test "keeps non-poll requests at info level" do
    assert Endpoint.request_log_level(conn("/api/outlet/complete/")) == :info
    assert Endpoint.request_log_level(conn("/api/outlet/complete/", 200)) == :info
    assert Endpoint.request_log_level(conn("/api/outlet/poll-status", 200)) == :info
  end

  defp conn(path, status \\ nil) do
    :get
    |> Plug.Test.conn(path)
    |> Map.put(:status, status)
  end
end
