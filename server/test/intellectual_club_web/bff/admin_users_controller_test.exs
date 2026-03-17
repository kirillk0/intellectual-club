defmodule IntellectualClubWeb.Bff.AdminUsersControllerTest do
  @moduledoc """
  Tests for SPA administrative user management endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Accounts.{User, UserGroup}

  test "GET /api/bff/admin/users returns users for admins", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: regular} = user_fixture(%{username: "member_one"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> get("/api/bff/admin/users")
      |> json_response(200)

    usernames = response["users"] |> Enum.map(& &1["username"])

    assert usernames == Enum.sort([admin.username, regular.username])
  end

  test "GET /api/bff/admin/users returns 403 for non-admins", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> get("/api/bff/admin/users")
      |> json_response(403)

    assert response["error"] == "Forbidden"
  end

  test "POST /api/bff/admin/users creates a user", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{group: group} = user_group_fixture(%{name: "staff_group"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> post("/api/bff/admin/users", %{
        "username" => "new_admin_user",
        "is_admin" => true,
        "group_ids" => [group.id],
        "password" => "new-password-1234",
        "password_confirmation" => "new-password-1234"
      })
      |> json_response(201)

    created_id = get_in(response, ["user", "id"])

    assert get_in(response, ["user", "username"]) == "new_admin_user"
    assert get_in(response, ["user", "is_admin"]) == true
    assert get_in(response, ["user", "groups"]) == [%{"id" => group.id, "name" => group.name}]
    assert {:ok, %User{id: ^created_id}} = Ash.get(User, created_id, authorize?: false)
  end

  test "PATCH /api/bff/admin/users/:id updates a user", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: target} = user_fixture(%{username: "plain_user"})
    %{group: group} = user_group_fixture(%{name: "ops_team"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> patch("/api/bff/admin/users/#{target.id}", %{
        "username" => "renamed_user",
        "is_admin" => true,
        "group_ids" => [group.id]
      })
      |> json_response(200)

    assert get_in(response, ["user", "username"]) == "renamed_user"
    assert get_in(response, ["user", "is_admin"]) == true
    assert get_in(response, ["user", "groups"]) == [%{"id" => group.id, "name" => group.name}]

    assert {:ok, %User{groups: [%UserGroup{id: group_id}]}} =
             Ash.get(User, target.id, authorize?: false, load: [:groups])

    assert group_id == group.id
  end

  test "PATCH /api/bff/admin/users/:id rejects removing own admin access", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> patch("/api/bff/admin/users/#{admin.id}", %{
        "username" => admin.username,
        "is_admin" => false
      })
      |> json_response(422)

    assert get_in(response, ["errors", "is_admin"]) == [
             "cannot remove admin access from yourself."
           ]
  end

  test "DELETE /api/bff/admin/users/:id deletes another user", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: target} = user_fixture(%{username: "delete_me"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> delete("/api/bff/admin/users/#{target.id}")
      |> json_response(200)

    assert response["detail"] == "ok"

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(User, target.id, authorize?: false)
  end

  test "DELETE /api/bff/admin/users/:id rejects deleting yourself", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> delete("/api/bff/admin/users/#{admin.id}")
      |> json_response(422)

    assert get_in(response, ["errors", "_form"]) == ["cannot delete yourself."]
  end

  test "POST /api/bff/admin/users/:id/reset-password resets password", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: target} = user_fixture(%{username: "reset_target"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> post("/api/bff/admin/users/#{target.id}/reset-password", %{
        "password" => "reset-password-1234",
        "password_confirmation" => "reset-password-1234"
      })
      |> json_response(200)

    assert get_in(response, ["user", "id"]) == target.id

    conn
    |> recycle()
    |> post("/api/bff/auth/login", %{
      "username" => target.username,
      "password" => "reset-password-1234"
    })
    |> json_response(200)
  end
end
