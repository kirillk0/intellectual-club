defmodule IntellectualClubWeb.Bff.MeControllerTest do
  @moduledoc """
  Tests for user settings endpoints served by MeController.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Accounts.User

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
end
