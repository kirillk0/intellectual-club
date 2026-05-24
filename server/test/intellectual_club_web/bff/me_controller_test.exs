defmodule IntellectualClubWeb.Bff.MeControllerTest do
  @moduledoc """
  Tests for user settings endpoints served by MeController.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Accounts.User

  test "GET /api/bff/me returns current user with nullable preferred locale", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    response =
      conn
      |> get("/api/bff/me")
      |> json_response(200)

    assert get_in(response, ["user", "id"]) == actor.id
    assert get_in(response, ["user", "preferred_locale"]) == nil
  end

  test "PATCH /api/bff/me updates preferred locale", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    response =
      conn
      |> patch("/api/bff/me", %{"preferred_locale" => "ru"})
      |> json_response(200)

    assert get_in(response, ["user", "preferred_locale"]) == "ru"

    response =
      conn
      |> patch("/api/bff/me", %{"preferred_locale" => "en"})
      |> json_response(200)

    assert get_in(response, ["user", "preferred_locale"]) == "en"

    response =
      conn
      |> patch("/api/bff/me", %{"preferred_locale" => nil})
      |> json_response(200)

    assert get_in(response, ["user", "preferred_locale"]) == nil
  end

  test "PATCH /api/bff/me rejects unsupported preferred locale", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    response =
      conn
      |> patch("/api/bff/me", %{"preferred_locale" => "de"})
      |> json_response(422)

    assert response["detail"] == "Validation failed"
    assert get_in(response, ["errors", "preferred_locale"])
  end

  test "update_settings cannot update another user", _context do
    %{user: actor} = user_fixture()
    %{user: other_user} = user_fixture()

    assert {:error, %Ash.Error.Forbidden{}} =
             other_user
             |> Ash.Changeset.for_update(:update_settings, %{preferred_locale: "ru"},
               actor: actor
             )
             |> Ash.update()
  end

  test "PATCH /api/bff/me localizes validation errors", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    response =
      conn
      |> put_req_header("x-ui-locale", "ru")
      |> patch("/api/bff/me", %{"preferred_locale" => "de"})
      |> json_response(422)

    assert response["detail"] == translated("ru", "Validation failed")
    assert get_in(response, ["errors", "preferred_locale"])
  end

  test "POST /api/bff/me/change-password updates password", %{conn: conn} do
    %{user: actor, password: old_password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, old_password)

    payload = %{
      "current_password" => old_password,
      "new_password" => "new-password-5678",
      "new_password_confirm" => "new-password-5678"
    }

    response =
      conn
      |> post("/api/bff/me/change-password", payload)
      |> json_response(200)

    assert response["detail"] == "ok"

    strategy = AshAuthentication.Info.strategy!(User, :password)

    assert {:ok, _updated_user} =
             AshAuthentication.Strategy.action(strategy, :sign_in, %{
               "username" => actor.username,
               "password" => "new-password-5678"
             })

    assert {:error, _error} =
             AshAuthentication.Strategy.action(strategy, :sign_in, %{
               "username" => actor.username,
               "password" => old_password
             })
  end

  test "POST /api/bff/me/change-password returns field error on invalid current password", %{
    conn: conn
  } do
    %{user: actor, password: old_password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, old_password)

    payload = %{
      "current_password" => "wrong-password",
      "new_password" => "new-password-5678",
      "new_password_confirm" => "new-password-5678"
    }

    response =
      conn
      |> post("/api/bff/me/change-password", payload)
      |> json_response(422)

    assert response["detail"] == "Validation failed"
    assert get_in(response, ["errors", "current_password"]) == ["Current password is incorrect."]
  end

  test "POST /api/bff/me/change-password returns field error on password confirmation mismatch",
       %{
         conn: conn
       } do
    %{user: actor, password: old_password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, old_password)

    payload = %{
      "current_password" => old_password,
      "new_password" => "new-password-5678",
      "new_password_confirm" => "new-password-9999"
    }

    response =
      conn
      |> post("/api/bff/me/change-password", payload)
      |> json_response(422)

    assert response["detail"] == "Validation failed"

    assert Enum.any?(get_in(response, ["errors", "new_password_confirm"]) || [], fn message ->
             String.contains?(message, "does not match")
           end)
  end

  defp translated(locale, msgid) do
    Gettext.with_locale(IntellectualClubWeb.Gettext, locale, fn ->
      Gettext.gettext(IntellectualClubWeb.Gettext, msgid)
    end)
  end
end
