defmodule IntellectualClubWeb.AshJsonApi.AdminAccountsTest do
  @moduledoc """
  Regression tests for administrative accounts management over Ash JSON:API.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Accounts.{User, UserGroup}

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  defp json_api_patch(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, body)
  end

  defp json_api_delete(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> delete(path)
  end

  defp json_api_payload(type, attributes, id \\ nil) do
    data =
      %{
        "type" => type,
        "attributes" => attributes
      }
      |> maybe_put_id(id)

    %{"data" => data}
  end

  defp maybe_put_id(data, nil), do: data
  defp maybe_put_id(data, id), do: Map.put(data, "id", to_string(id))

  defp ids_from_data(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp ids_from_included(%{"included" => included}, type) when is_list(included) do
    included
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp ids_from_included(_response, _type), do: []

  defp error_details(%{"errors" => errors}) when is_list(errors) do
    Enum.map(errors, fn error ->
      error["detail"] || error["title"] || ""
    end)
  end

  defp assert_timestamp_attributes(%{"attributes" => attributes}) do
    assert is_binary(attributes["created_at"])
    assert attributes["created_at"] != ""
    assert is_binary(attributes["updated_at"])
    assert attributes["updated_at"] != ""
  end

  test "GET /api/ash/users lists users with included groups for admins", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: regular} = user_fixture(%{username: "member_one"})
    %{group: group} = user_group_fixture(%{name: "staff_group", users: [regular]})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> json_api_get("/api/ash/users?sort=username&include=groups")
      |> json_response(200)

    assert ids_from_data(response) == Enum.sort([admin.id, regular.id])
    assert ids_from_included(response, "user-groups") == [group.id]

    response["data"]
    |> Enum.each(&assert_timestamp_attributes/1)
  end

  test "GET /api/ash/users returns 403 for non-admins", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> json_api_get("/api/ash/users")

    assert response.status == 403
  end

  test "POST and PATCH /api/ash/users create and update users with groups", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{group: group} = user_group_fixture(%{name: "ops_team"})

    created =
      conn
      |> sign_in_conn(admin.username, password)
      |> json_api_post(
        "/api/ash/users?include=groups",
        json_api_payload("users", %{
          "username" => "new_admin_user",
          "is_admin" => true,
          "groups" => [group.id],
          "password" => "new-password-1234",
          "password_confirmation" => "new-password-1234"
        })
      )
      |> json_response(201)

    created_id = created["data"]["id"] |> String.to_integer()

    assert get_in(created, ["data", "attributes", "username"]) == "new_admin_user"
    assert get_in(created, ["data", "attributes", "is_admin"]) == true
    assert ids_from_included(created, "user-groups") == [group.id]
    assert_timestamp_attributes(created["data"])

    updated =
      conn
      |> recycle()
      |> sign_in_conn(admin.username, password)
      |> json_api_patch(
        "/api/ash/users/#{created_id}?include=groups",
        json_api_payload(
          "users",
          %{
            "username" => "renamed_user",
            "is_admin" => false,
            "groups" => []
          },
          created_id
        )
      )
      |> json_response(200)

    assert get_in(updated, ["data", "attributes", "username"]) == "renamed_user"
    assert get_in(updated, ["data", "attributes", "is_admin"]) == false
    assert_timestamp_attributes(updated["data"])

    assert {:ok, %User{groups: []}} =
             Ash.get(User, created_id, authorize?: false, load: [:groups])
  end

  test "PATCH /api/ash/users/:id rejects removing own admin access", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> json_api_patch(
        "/api/ash/users/#{admin.id}",
        json_api_payload(
          "users",
          %{
            "username" => admin.username,
            "is_admin" => false
          },
          admin.id
        )
      )
      |> json_response(400)

    assert Enum.any?(error_details(response), &String.contains?(&1, "cannot remove admin access"))
  end

  test "DELETE /api/ash/users/:id deletes another user and rejects deleting yourself", %{
    conn: conn
  } do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: target} = user_fixture(%{username: "delete_me"})

    delete_conn =
      conn
      |> sign_in_conn(admin.username, password)
      |> json_api_delete("/api/ash/users/#{target.id}")

    assert delete_conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(User, target.id, authorize?: false)

    response =
      conn
      |> recycle()
      |> sign_in_conn(admin.username, password)
      |> json_api_delete("/api/ash/users/#{admin.id}")
      |> json_response(400)

    assert Enum.any?(error_details(response), &String.contains?(&1, "cannot delete yourself"))
  end

  test "PATCH /api/ash/users/:id/reset-password resets passwords", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: target} = user_fixture(%{username: "reset_target"})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> json_api_patch(
        "/api/ash/users/#{target.id}/reset-password",
        json_api_payload(
          "users",
          %{
            "password" => "reset-password-1234",
            "password_confirmation" => "reset-password-1234"
          },
          target.id
        )
      )
      |> json_response(200)

    assert get_in(response, ["data", "id"]) == Integer.to_string(target.id)
    assert_timestamp_attributes(response["data"])

    conn
    |> recycle()
    |> post("/api/bff/auth/login", %{
      "username" => target.username,
      "password" => "reset-password-1234"
    })
    |> json_response(200)
  end

  test "GET /api/ash/user-groups lists groups with included users for admins", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: member} = user_fixture(%{username: "member_two"})
    %{group: group} = user_group_fixture(%{name: "engineering", users: [member]})

    response =
      conn
      |> sign_in_conn(admin.username, password)
      |> json_api_get("/api/ash/user-groups?sort=name&include=users")
      |> json_response(200)

    assert ids_from_data(response) == [group.id]
    assert ids_from_included(response, "users") == [member.id]

    response["data"]
    |> Enum.each(&assert_timestamp_attributes/1)
  end

  test "GET /api/ash/user-groups returns 403 for non-admins", %{conn: conn} do
    %{user: user, password: password} = user_fixture()
    %{group: _group} = user_group_fixture(%{users: [user]})

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> json_api_get("/api/ash/user-groups")

    assert response.status == 403
  end

  test "POST and PATCH /api/ash/user-groups create and update membership", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{user: first_user} = user_fixture(%{username: "first_member"})
    %{user: second_user} = user_fixture(%{username: "second_member", is_admin: true})

    created =
      conn
      |> sign_in_conn(admin.username, password)
      |> json_api_post(
        "/api/ash/user-groups?include=users",
        json_api_payload("user-groups", %{
          "name" => "moderators",
          "users" => [first_user.id]
        })
      )
      |> json_response(201)

    created_id = created["data"]["id"] |> String.to_integer()

    assert get_in(created, ["data", "attributes", "name"]) == "moderators"
    assert ids_from_included(created, "users") == [first_user.id]
    assert_timestamp_attributes(created["data"])

    updated =
      conn
      |> recycle()
      |> sign_in_conn(admin.username, password)
      |> json_api_patch(
        "/api/ash/user-groups/#{created_id}?include=users",
        json_api_payload(
          "user-groups",
          %{
            "name" => "core_reviewers",
            "users" => [second_user.id]
          },
          created_id
        )
      )
      |> json_response(200)

    assert get_in(updated, ["data", "attributes", "name"]) == "core_reviewers"
    assert ids_from_included(updated, "users") == [second_user.id]
    assert_timestamp_attributes(updated["data"])
  end

  test "DELETE /api/ash/user-groups/:id deletes a group", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{group: group} = user_group_fixture(%{name: "temporary_group"})

    delete_conn =
      conn
      |> sign_in_conn(admin.username, password)
      |> json_api_delete("/api/ash/user-groups/#{group.id}")

    assert delete_conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(UserGroup, group.id, authorize?: false)
  end
end
