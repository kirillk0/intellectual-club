defmodule IntellectualClubWeb.PageControllerTest do
  use IntellectualClubWeb.ConnCase

  test "GET / redirects anonymous user to /login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /login serves SPA shell for anonymous user", %{conn: conn} do
    conn = get(conn, ~p"/login")
    html = html_response(conn, 200)
    assert html =~ ~s(id="spa-root")
  end

  test "GET /", %{conn: conn} do
    %{user: user, password: password} = user_fixture()
    conn = sign_in_conn(conn, user.username, password)

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ ~s(id="spa-root")
  end
end
