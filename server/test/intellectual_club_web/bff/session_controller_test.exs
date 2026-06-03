defmodule IntellectualClubWeb.Bff.SessionControllerTest do
  @moduledoc """
  Tests for SPA session endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  test "POST /api/bff/auth/login signs in and returns current user", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> post("/api/bff/auth/login", %{
        "username" => user.username,
        "password" => password
      })
      |> json_response(200)

    assert get_in(response, ["user", "id"]) == user.id
    assert get_in(response, ["user", "username"]) == user.username
    assert get_in(response, ["user", "is_admin"]) == user.is_admin
    assert get_in(response, ["user", "preferred_locale"]) == nil
    assert get_in(response, ["user", "preferred_theme"]) == "system"
  end

  test "POST /api/bff/auth/login returns 401 for invalid credentials", %{conn: conn} do
    %{user: user} = user_fixture()

    response =
      conn
      |> post("/api/bff/auth/login", %{
        "username" => user.username,
        "password" => "wrong-password"
      })
      |> json_response(401)

    assert response["detail"] == "Incorrect username or password."
  end

  test "POST /api/bff/auth/login localizes controlled errors", %{conn: conn} do
    %{user: user} = user_fixture()

    response =
      conn
      |> put_req_header("x-ui-locale", "ru")
      |> post("/api/bff/auth/login", %{
        "username" => user.username,
        "password" => "wrong-password"
      })
      |> json_response(401)

    assert response["detail"] == translated("ru", "Incorrect username or password.")
  end

  test "GET /api/bff/auth/me returns 401 for anonymous request", %{conn: conn} do
    response =
      conn
      |> get("/api/bff/auth/me")
      |> json_response(401)

    assert response["error"] == "Unauthorized"
  end

  test "GET /api/bff/auth/me returns current user for authenticated request", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> get("/api/bff/auth/me")
      |> json_response(200)

    assert get_in(response, ["user", "id"]) == user.id
    assert get_in(response, ["user", "username"]) == user.username
    assert get_in(response, ["user", "is_admin"]) == user.is_admin
    assert get_in(response, ["user", "preferred_locale"]) == nil
    assert get_in(response, ["user", "preferred_theme"]) == "system"
  end

  test "POST /api/bff/auth/logout clears authenticated session", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    conn =
      conn
      |> sign_in_conn(user.username, password)
      |> post("/api/bff/auth/logout", %{})

    assert json_response(conn, 200)["detail"] == "ok"

    conn
    |> recycle()
    |> get("/api/bff/auth/me")
    |> json_response(401)
  end

  defp translated(locale, msgid) do
    Gettext.with_locale(IntellectualClubWeb.Gettext, locale, fn ->
      Gettext.gettext(IntellectualClubWeb.Gettext, msgid)
    end)
  end
end
