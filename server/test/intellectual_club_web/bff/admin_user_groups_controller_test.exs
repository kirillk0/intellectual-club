defmodule IntellectualClubWeb.Bff.AdminUserGroupsControllerTest do
  @moduledoc """
  Tests for SPA administrative user group management endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Accounts.UserGroup

  test "GET /api/bff/admin/user-groups returns groups for admins", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{group: group} = user_group_fixture(%{name: "engineering"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> get("/api/bff/admin/user-groups")
      |> json_response(200)

    assert response["groups"] == [
             %{
               "id" => group.id,
               "name" => "engineering",
               "created_at" => response["groups"] |> hd() |> Map.get("created_at"),
               "updated_at" => response["groups"] |> hd() |> Map.get("updated_at"),
               "users" => []
             }
           ]
  end

  test "GET /api/bff/admin/user-groups returns 403 for non-admins", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> get("/api/bff/admin/user-groups")
      |> json_response(403)

    assert response["error"] == "Forbidden"
  end

  test "POST /api/bff/admin/user-groups creates a group with users", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: member} = user_fixture(%{username: "member_one"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> post("/api/bff/admin/user-groups", %{
        "name" => "moderators",
        "user_ids" => [member.id]
      })
      |> json_response(201)

    created_id = get_in(response, ["group", "id"])

    assert get_in(response, ["group", "name"]) == "moderators"

    assert get_in(response, ["group", "users"]) == [
             %{"id" => member.id, "username" => member.username, "is_admin" => false}
           ]

    assert {:ok, %UserGroup{id: ^created_id}} = Ash.get(UserGroup, created_id, authorize?: false)
  end

  test "PATCH /api/bff/admin/user-groups/:id updates membership", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: first_user} = user_fixture(%{username: "first_member"})
    %{user: second_user} = user_fixture(%{username: "second_member", is_admin: true})
    %{group: group} = user_group_fixture(%{name: "reviewers", users: [first_user]})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> patch("/api/bff/admin/user-groups/#{group.id}", %{
        "name" => "core_reviewers",
        "user_ids" => [second_user.id]
      })
      |> json_response(200)

    assert get_in(response, ["group", "name"]) == "core_reviewers"

    assert get_in(response, ["group", "users"]) == [
             %{"id" => second_user.id, "username" => second_user.username, "is_admin" => true}
           ]
  end

  test "DELETE /api/bff/admin/user-groups/:id deletes a group", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{group: group} = user_group_fixture(%{name: "temporary_group"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> delete("/api/bff/admin/user-groups/#{group.id}")
      |> json_response(200)

    assert response["detail"] == "ok"

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(UserGroup, group.id, authorize?: false)
  end
end
