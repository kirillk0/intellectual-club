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
    assert html =~ ~s(id="spa-bootstrap-shell")
    assert html =~ ~s(id="spa-bootstrap-status")
    assert html =~ ~s(class="spa-bootstrap-panel spa-bootstrap-content")
    assert html =~ ~s(name="ic-build-id")
    assert html =~ "window.__IC_BOOTSTRAP__"
    assert html =~ "window.__IC_SERVICE_WORKER_REGISTRATION__"
    assert html =~ "'/service-worker.js'"
    refute html =~ "/service-worker.js?build="
    assert html =~ "ic:bootstrap-state"
    assert html =~ "updateViaCache: 'none'"
    assert html =~ "data-bootstrap-step=\"runtime\""
    {bootstrap_offset, _length} = :binary.match(html, "window.__IC_SERVICE_WORKER_REGISTRATION__")
    {module_offset, _length} = :binary.match(html, ~s(type="module"))
    assert bootstrap_offset < module_offset
    refute html =~ ~s(class="spa-boot")
    refute html =~ ">Reload<"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "GET /", %{conn: conn} do
    %{user: user, password: password} = user_fixture()
    conn = sign_in_conn(conn, user.username, password)

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ ~s(id="spa-root")
    assert html =~ ~s(id="spa-bootstrap-shell")
    assert html =~ ~s(id="spa-bootstrap-status")
    assert html =~ "Preparing the interface…"
    assert html =~ "Waiting for a connection…"
    assert html =~ "Restoring the connection…"
    assert html =~ "Application startup progress"
    assert html =~ "window.location.replace(window.location.href)"
    assert html =~ "historyReloadGuardKey = '__icBootstrapReload'"
    assert html =~ "sessionStorage.getItem(reloadGuardKey) === reloadId"
    refute html =~ "reloadGuardWindowMs"
    refute html =~ "spa-boot__reload"
    refute html =~ "window.location.reload()"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "GET / localizes delayed startup status before JavaScript starts", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    conn =
      conn
      |> sign_in_conn(user.username, password)
      |> put_req_header("accept-language", "ru")
      |> get(~p"/")

    html = html_response(conn, 200)
    assert html =~ ~s(<html lang="ru")
    assert html =~ "Подготавливаем интерфейс…"
    assert html =~ "Ожидаем подключения…"
    assert html =~ "Восстанавливаем подключение…"
    assert html =~ "Интерфейс"
    assert html =~ "Раздел"
    assert html =~ "Данные"
    refute html =~ "Перезагрузить"
  end

  test "GET /health returns a dependency-free no-store liveness response", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute Map.has_key?(conn.private, :plug_session)
  end

  test "GET /manifest.webmanifest serves PWA manifest", %{conn: conn} do
    conn = get(conn, ~p"/manifest.webmanifest")

    assert json_response(conn, 200)["name"] == "Intellectual Club"
  end

  test "GET /service-worker.js serves recovery service worker", %{conn: conn} do
    conn = get(conn, ~p"/service-worker.js")

    service_worker = response(conn, 200)
    assert service_worker =~ "pwa-precache-manifest.js"
    assert service_worker =~ "fetch"
    assert service_worker =~ "caches"
  end

  test "GET /apple-touch-icon.png serves touch icon", %{conn: conn} do
    conn = get(conn, ~p"/apple-touch-icon.png")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["image/png"]
  end

  test "GET digested favicon serves icon", %{conn: conn} do
    static_dir = Application.app_dir(:intellectual_club, "priv/static")
    digested_favicon = "favicon-testdigest.png"
    digested_path = Path.join(static_dir, digested_favicon)

    File.cp!(Path.join(static_dir, "favicon.png"), digested_path)
    on_exit(fn -> File.rm(digested_path) end)

    conn = get(conn, "/" <> digested_favicon <> "?vsn=d")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["image/png"]
  end
end
