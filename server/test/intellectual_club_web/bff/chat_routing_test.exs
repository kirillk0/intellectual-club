defmodule IntellectualClubWeb.Bff.ChatRoutingTest do
  use IntellectualClubWeb.ConnCase, async: false

  test "old chat BFF routes no longer match", %{conn: conn} do
    assert conn |> get("/api/bff/chats") |> response(404)
    assert build_conn() |> get("/api/bff/chats/123/state") |> response(404)
  end
end
