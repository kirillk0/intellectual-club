defmodule IntellectualClubWeb.AdminPagesTest do
  use IntellectualClubWeb.ConnCase, async: false

  test "administration SPA shell renders for signed-in admin", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    conn = sign_in_conn(conn, admin.username, password)

    for path <- [
          ~p"/administration",
          ~p"/administration/users",
          ~p"/administration/users/new",
          ~p"/administration/user-groups",
          ~p"/administration/user-groups/new"
        ] do
      html =
        conn
        |> get(path)
        |> html_response(200)

      assert html =~ ~s(id="spa-root")
      assert html =~ ~s(data-current-user-is-admin="true")
      assert html =~ admin.username
    end
  end
end
