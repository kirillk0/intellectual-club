defmodule IntellectualClubWeb.EndpointTest do
  use ExUnit.Case, async: true

  alias IntellectualClubWeb.Endpoint

  test "uses debug logging for GET requests before a response is sent" do
    assert Endpoint.request_log_level(conn(:get, "/api/bff/chat-list")) == :debug
    assert Endpoint.request_log_level(conn(:get, "/api/bff/chat-list/idle-state")) == :debug

    assert Endpoint.request_log_level(conn(:get, "/api/bff/chat-messages/2960/contents/1/file")) ==
             :debug
  end

  test "uses debug logging for GET responses with status 200 or 204" do
    assert Endpoint.request_log_level(conn(:get, "/api/bff/chat-list", 200)) == :debug
    assert Endpoint.request_log_level(conn(:get, "/api/bff/chat-list/idle-state", 204)) == :debug
    assert Endpoint.request_log_level(conn(:get, "/api/ash/bots", 200)) == :debug
  end

  test "keeps other GET response statuses at info level" do
    for status <- [206, 301, 304, 400, 404, 500] do
      assert Endpoint.request_log_level(conn(:get, "/api/bff/chat-list", status)) == :info
    end
  end

  test "continues to use debug logging for successful poll requests with other methods" do
    assert Endpoint.request_log_level(conn(:post, "/api/outlet/poll/")) == :debug
    assert Endpoint.request_log_level(conn(:post, "/api/outlet/pair/poll/", 200)) == :debug
    assert Endpoint.request_log_level(conn(:post, "/api/outlet/poll/", 400)) == :info
    assert Endpoint.request_log_level(conn(:post, "/api/outlet/poll/", 500)) == :info
  end

  test "keeps other methods at info level" do
    assert Endpoint.request_log_level(conn(:post, "/api/outlet/complete/")) == :info
    assert Endpoint.request_log_level(conn(:post, "/api/outlet/complete/", 200)) == :info
    assert Endpoint.request_log_level(conn(:head, "/api/bff/chat-list", 200)) == :info

    transformed_head_conn =
      :head
      |> conn("/api/bff/chat-list", 200)
      |> Plug.Conn.put_private(:intellectual_club_request_method, "HEAD")
      |> Map.put(:method, "GET")

    assert Endpoint.request_log_level(transformed_head_conn) == :info
  end

  defp conn(method, path, status \\ nil) do
    method
    |> Plug.Test.conn(path)
    |> Map.put(:status, status)
  end
end
