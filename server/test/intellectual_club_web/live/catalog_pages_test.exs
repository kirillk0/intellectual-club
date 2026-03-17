defmodule IntellectualClubWeb.CatalogPagesTest do
  use IntellectualClubWeb.ConnCase, async: false

  test "catalog SPA shell renders", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    for path <- [
          ~p"/catalogs",
          ~p"/catalogs/knowledge-blocks",
          ~p"/catalogs/knowledge-blocks/new",
          ~p"/catalogs/knowledge-tags",
          ~p"/catalogs/bots",
          ~p"/catalogs/llm-providers",
          ~p"/catalogs/llm-configurations"
        ] do
      html =
        conn
        |> get(path)
        |> html_response(200)

      assert html =~ ~s(id="spa-root")
      assert html =~ actor.username
    end
  end
end
