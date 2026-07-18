defmodule IntellectualClubWeb.Bff.SessionControllerTest do
  @moduledoc """
  Tests for SPA session endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Accounts.User

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

    refreshed = Ash.get!(User, user.id, authorize?: false)
    assert %DateTime{} = refreshed.last_activity_at
  end

  test "POST /api/bff/auth/login returns 401 for invalid credentials", %{conn: conn} do
    %{user: user} = user_fixture()
    before = Ash.get!(User, user.id, authorize?: false)

    response =
      conn
      |> post("/api/bff/auth/login", %{
        "username" => user.username,
        "password" => "wrong-password"
      })
      |> json_response(401)

    assert response["detail"] == "Incorrect username or password."

    after_attempt = Ash.get!(User, user.id, authorize?: false)
    assert after_attempt.last_activity_at == before.last_activity_at
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

  test "GET /api/bff/auth/bootstrap returns an anonymous session and CSRF token", %{
    conn: conn
  } do
    response =
      conn
      |> get("/api/bff/auth/bootstrap")
      |> json_response(200)

    assert response["user"] == nil
    assert is_binary(response["csrf_token"])
    assert response["csrf_token"] != ""
  end

  test "GET /api/bff/auth/bootstrap returns the authenticated user", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> get("/api/bff/auth/bootstrap")
      |> json_response(200)

    assert get_in(response, ["user", "id"]) == user.id
    assert get_in(response, ["user", "username"]) == user.username
    assert is_binary(response["csrf_token"])
    assert response["csrf_token"] != ""
  end

  test "GET /api/bff/auth/me returns current user for authenticated request", %{conn: conn} do
    %{user: user, password: password} = user_fixture()
    before = Ash.get!(User, user.id, authorize?: false)

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

    refreshed = Ash.get!(User, user.id, authorize?: false)
    assert %DateTime{} = refreshed.last_activity_at
    assert DateTime.compare(refreshed.updated_at, before.updated_at) == :eq
  end

  test "authenticated API activity is throttled", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    conn
    |> sign_in_conn(user.username, password)
    |> get("/api/bff/auth/me")
    |> json_response(200)

    first_activity = Ash.get!(User, user.id, authorize?: false).last_activity_at
    assert %DateTime{} = first_activity

    conn
    |> recycle()
    |> sign_in_conn(user.username, password)
    |> get("/api/bff/auth/me")
    |> json_response(200)

    second_activity = Ash.get!(User, user.id, authorize?: false).last_activity_at
    assert DateTime.compare(second_activity, first_activity) == :eq
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
