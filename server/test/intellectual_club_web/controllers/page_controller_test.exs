defmodule IntellectualClubWeb.PageControllerTest do
  use IntellectualClubWeb.ConnCase

  test "GET / redirects anonymous user to /login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login?next=#{"/"}"
  end

  test "GET nested SPA route redirects anonymous user to login with next path", %{conn: conn} do
    conn = get(conn, ~p"/catalogs/bots/42?panel=shares")
    assert redirected_to(conn) == ~p"/login?next=#{"/catalogs/bots/42?panel=shares"}"
  end

  test "GET /login serves SPA shell for anonymous user", %{conn: conn} do
    conn = get(conn, ~p"/login")
    html = html_response(conn, 200)
    assert html =~ ~s(id="spa-root")
    assert html =~ ~s(content="width=device-width, initial-scale=1, viewport-fit=cover")
    assert html =~ ~s(name="theme-color")
    assert html =~ ~s(name="apple-mobile-web-app-capable" content="yes")
    assert html =~ ~s(name="apple-mobile-web-app-title" content="Intellectual Club")
    assert html =~ ~s(name="apple-mobile-web-app-status-bar-style" content="default")
    assert html =~ ~s(rel="manifest" href="/manifest.webmanifest")
    assert html =~ ~s(rel="apple-touch-icon" href="/apple-touch-icon.png")
  end

  test "GET /", %{conn: conn} do
    %{user: user, password: password} = user_fixture()
    conn = sign_in_conn(conn, user.username, password)

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ ~s(id="spa-root")
  end

  test "GET /manifest.webmanifest serves PWA manifest", %{conn: conn} do
    conn = get(conn, ~p"/manifest.webmanifest")

    assert json_response(conn, 200)["name"] == "Intellectual Club"
  end

  test "GET /service-worker.js serves online-only service worker", %{conn: conn} do
    conn = get(conn, ~p"/service-worker.js")

    assert response(conn, 200) =~ "skipWaiting"
    refute response(conn, 200) =~ "fetch"
    refute response(conn, 200) =~ "caches"
  end

  test "GET /apple-touch-icon.png serves touch icon", %{conn: conn} do
    conn = get(conn, ~p"/apple-touch-icon.png")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["image/png"]
  end
end
