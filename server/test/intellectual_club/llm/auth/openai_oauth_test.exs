defmodule IntellectualClub.Llm.Auth.OpenAIOAuthTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Llm.Auth
  alias IntellectualClub.Llm.Auth.OpenAIOAuth
  alias IntellectualClub.Llm.LlmProvider

  setup do
    table = :ic_openai_oauth_token_cache

    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    :ok
  end

  test "returns API key as bearer token" do
    assert Auth.get_bearer_token(%{auth_method: :api_key, api_key: "  k  "}) == {:ok, "k"}
  end

  test "refreshes, caches access token, and rotates refresh token" do
    %{user: actor} = user_fixture()
    refresh_token = "rt_" <> Integer.to_string(System.unique_integer([:positive]))
    next_refresh_token = "rt_next_" <> Integer.to_string(System.unique_integer([:positive]))

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Responses OAuth",
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          oauth_refresh_token: refresh_token
        },
        actor: actor
      )
      |> Ash.create!()

    Req.Test.expect(OpenAIOAuth, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == refresh_token

      Req.Test.json(conn, %{
        "access_token" => "at_1",
        "refresh_token" => next_refresh_token,
        "expires_in" => 3600,
        "token_type" => "Bearer"
      })
    end)

    assert OpenAIOAuth.get_access_token(refresh_token, provider_id: provider.id) == {:ok, "at_1"}

    reloaded_provider = Ash.get!(LlmProvider, provider.id, actor: actor)
    assert reloaded_provider.oauth_refresh_token == next_refresh_token

    assert OpenAIOAuth.get_access_token(refresh_token, provider_id: provider.id) == {:ok, "at_1"}
  end

  test "uses rotated refresh token on subsequent refresh" do
    %{user: actor} = user_fixture()
    refresh_token = "rt_" <> Integer.to_string(System.unique_integer([:positive]))
    refresh_token_2 = "rt_2_" <> Integer.to_string(System.unique_integer([:positive]))
    refresh_token_3 = "rt_3_" <> Integer.to_string(System.unique_integer([:positive]))

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Responses OAuth (short lived)",
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          oauth_refresh_token: refresh_token
        },
        actor: actor
      )
      |> Ash.create!()

    Req.Test.expect(OpenAIOAuth, 2, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      call = Process.get(:openai_oauth_calls, 0)
      Process.put(:openai_oauth_calls, call + 1)

      if call == 0 do
        assert params["refresh_token"] == refresh_token

        Req.Test.json(conn, %{
          "access_token" => "at_1",
          "refresh_token" => refresh_token_2,
          "expires_in" => 1
        })
      else
        assert params["refresh_token"] == refresh_token_2

        Req.Test.json(conn, %{
          "access_token" => "at_2",
          "refresh_token" => refresh_token_3,
          "expires_in" => 3600
        })
      end
    end)

    assert OpenAIOAuth.get_access_token(refresh_token, provider_id: provider.id) == {:ok, "at_1"}
    assert OpenAIOAuth.get_access_token(refresh_token, provider_id: provider.id) == {:ok, "at_2"}

    reloaded_provider = Ash.get!(LlmProvider, provider.id, actor: actor)
    assert reloaded_provider.oauth_refresh_token == refresh_token_3
  end

  test "returns error on refresh failure" do
    %{user: actor} = user_fixture()
    refresh_token = "rt_" <> Integer.to_string(System.unique_integer([:positive]))

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Responses OAuth (broken)",
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          oauth_refresh_token: refresh_token
        },
        actor: actor
      )
      |> Ash.create!()

    Req.Test.stub(OpenAIOAuth, fn conn ->
      body = Jason.encode!(%{"error_description" => "invalid_grant"})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, body)
    end)

    assert {:error, message} =
             OpenAIOAuth.get_access_token(refresh_token, provider_id: provider.id)

    assert message =~ "status 400"
    assert message =~ "invalid_grant"
  end

  test "uses refresh token auth method in Auth.get_bearer_token/1" do
    refresh_token = "rt_" <> Integer.to_string(System.unique_integer([:positive]))

    Req.Test.stub(OpenAIOAuth, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "at_from_auth",
        "refresh_token" => "rt_rotated",
        "expires_in" => 3600
      })
    end)

    assert Auth.get_bearer_token(%{
             auth_method: :openai_oauth_refresh_token,
             oauth_refresh_token: refresh_token
           }) == {:ok, "at_from_auth"}
  end

  test "prefers stored refresh token over caller input when provider_id is present" do
    %{user: actor} = user_fixture()
    refresh_token_db = "rt_db_" <> Integer.to_string(System.unique_integer([:positive]))

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Responses OAuth (stored token)",
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          oauth_refresh_token: refresh_token_db
        },
        actor: actor
      )
      |> Ash.create!()

    Req.Test.expect(OpenAIOAuth, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["refresh_token"] == refresh_token_db

      Req.Test.json(conn, %{
        "access_token" => "at_1",
        "refresh_token" => "rt_2",
        "expires_in" => 3600
      })
    end)

    assert OpenAIOAuth.get_access_token("rt_arg", provider_id: provider.id) == {:ok, "at_1"}
  end
end
