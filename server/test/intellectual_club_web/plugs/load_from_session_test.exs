defmodule IntellectualClubWeb.Plugs.LoadFromSessionTest do
  @moduledoc """
  Tests for loading the session user without losing the session on database failures.
  """

  use IntellectualClubWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias AshAuthentication.TokenResource
  alias IntellectualClub.Accounts.Token

  defmodule LiveTokenLookup do
    @moduledoc false
    @behaviour IntellectualClubWeb.Plugs.LoadFromSession.TokenLookup

    @impl true
    def lookup(jti) do
      send(self(), {:token_lookup, jti})
      {:ok, [%Token{jti: jti, purpose: "user"}]}
    end
  end

  defmodule UnavailableTokenLookup do
    @moduledoc false
    @behaviour IntellectualClubWeb.Plugs.LoadFromSession.TokenLookup

    @impl true
    def lookup(_jti) do
      {:error, DBConnection.ConnectionError.exception("connection not available")}
    end
  end

  setup %{conn: conn} do
    %{user: user, password: password} = user_fixture()
    conn = sign_in_conn(conn, user.username, password)
    %{conn: conn, user: user, token: get_session(conn, "user_token")}
  end

  describe "session user loading" do
    test "loads the user from a live session token", %{conn: conn, user: user, token: token} do
      conn = get(conn, "/api/bff/auth/me")

      assert get_in(json_response(conn, 200), ["user", "id"]) == user.id
      assert get_session(conn, "user_token") == token
    end

    test "clears the session when the token is no longer live", %{conn: conn, token: token} do
      :ok = TokenResource.Actions.revoke(Token, token)

      conn = get(conn, "/api/bff/auth/me")

      assert json_response(conn, 401)["error"] == "Unauthorized"
      assert get_session(conn, "user_token") == nil
    end

    test "keeps the session and answers 503 when the token record cannot be read", %{
      conn: conn,
      token: token
    } do
      put_app_env(:session_token_lookup, UnavailableTokenLookup)
      :ok = TokenResource.Actions.revoke(Token, token)

      {conn, log} =
        with_log(fn ->
          conn
          |> put_req_header("x-ui-locale", "ru")
          |> get("/api/bff/auth/me")
        end)

      assert json_response(conn, 503)["error"] ==
               "Сервис временно недоступен. Попробуйте ещё раз."

      assert get_resp_header(conn, "retry-after") == ["1"]
      assert conn.assigns.current_user == nil
      assert get_session(conn, "user_token") == token
      assert log =~ "Session user could not be verified, keeping the session"
    end

    test "serves the session bootstrap shell instead of the login redirect when the token record cannot be read",
         %{conn: conn, token: token} do
      put_app_env(:session_token_lookup, UnavailableTokenLookup)
      :ok = TokenResource.Actions.revoke(Token, token)

      {conn, _log} = with_log(fn -> get(conn, "/chats") end)

      assert html_response(conn, 200) =~ ~s(data-session-bootstrap="required")
      assert get_session(conn, "user_token") == token
    end

    test "retries a rejected load once while the token record is still live", %{
      conn: conn,
      token: token
    } do
      put_app_env(:session_token_lookup, LiveTokenLookup)
      :ok = TokenResource.Actions.revoke(Token, token)
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

      conn = get(conn, "/api/bff/auth/me")

      assert json_response(conn, 401)["error"] == "Unauthorized"
      assert get_session(conn, "user_token") == nil
      assert_received {:token_lookup, ^jti}
      assert_received {:token_lookup, ^jti}
      refute_received {:token_lookup, _jti}
    end
  end
end
