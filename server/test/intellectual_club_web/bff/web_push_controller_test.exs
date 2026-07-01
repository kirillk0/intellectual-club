defmodule IntellectualClubWeb.Bff.WebPushControllerTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Notifications
  alias IntellectualClub.Notifications.ActiveWebPushClients
  alias IntellectualClub.Notifications.WebPushSubscription

  require Ash.Query

  setup do
    ActiveWebPushClients.reset()

    on_exit(fn ->
      ActiveWebPushClients.reset()
    end)

    :ok
  end

  test "GET /api/bff/web-push/config returns current client configuration", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> get("/api/bff/web-push/config")
      |> json_response(200)

    assert response["enabled"] == false
    assert is_binary(response["vapid_public_key"])
    assert is_integer(response["key_revision"])
    refute Map.has_key?(response, "vapid_private_key")
  end

  test "subscription upsert and delete work for the current user", %{conn: conn} do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: user, password: password} = user_fixture()

    _settings = enable_settings!(admin)

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> put_req_header("user-agent", "test-agent")
      |> post(
        "/api/bff/web-push/subscriptions",
        subscription_payload("https://push.example/current")
      )
      |> json_response(200)

    assert response["status"] == "ok"
    assert get_in(response, ["subscription", "endpoint"]) == "https://push.example/current"
    assert get_in(response, ["subscription", "key_revision"]) == 1

    assert [_subscription] =
             WebPushSubscription
             |> Ash.Query.filter(
               owner_id == ^user.id and endpoint == "https://push.example/current"
             )
             |> Ash.read!(actor: user)

    delete_response =
      conn
      |> recycle()
      |> sign_in_conn(user.username, password)
      |> delete("/api/bff/web-push/subscriptions?endpoint=https%3A%2F%2Fpush.example%2Fcurrent")
      |> json_response(200)

    assert delete_response["status"] == "ok"

    assert [] =
             WebPushSubscription
             |> Ash.Query.filter(
               owner_id == ^user.id and endpoint == "https://push.example/current"
             )
             |> Ash.read!(actor: user)
  end

  test "subscription upsert rejects disabled Web Push", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> post(
        "/api/bff/web-push/subscriptions",
        subscription_payload("https://push.example/current")
      )
      |> json_response(422)

    assert response["detail"] == "Web Push is disabled."
  end

  test "client state endpoint records and clears current user visible chat", %{conn: conn} do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: user, password: password} = user_fixture()

    _settings = enable_settings!(admin)
    endpoint = "https://push.example/current"

    {:ok, _subscription} =
      Notifications.upsert_subscription(user, subscription_payload(endpoint))

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> post("/api/bff/web-push/client-state", %{
        "endpoint" => endpoint,
        "client_id" => "tab-1",
        "chat_id" => 123,
        "visible" => true
      })
      |> json_response(200)

    assert response["status"] == "ok"
    assert ActiveWebPushClients.active?(user.id, endpoint, 123)

    hidden_response =
      conn
      |> recycle()
      |> sign_in_conn(user.username, password)
      |> post("/api/bff/web-push/client-state", %{
        "endpoint" => endpoint,
        "client_id" => "tab-1",
        "chat_id" => 123,
        "visible" => false
      })
      |> json_response(200)

    assert hidden_response["status"] == "ok"
    refute ActiveWebPushClients.active?(user.id, endpoint, 123)
  end

  test "client state endpoint does not accept another user's subscription", %{conn: conn} do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: owner} = user_fixture()
    %{user: user, password: password} = user_fixture()

    _settings = enable_settings!(admin)
    endpoint = "https://push.example/owned"

    {:ok, _subscription} =
      Notifications.upsert_subscription(owner, subscription_payload(endpoint))

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> post("/api/bff/web-push/client-state", %{
        "endpoint" => endpoint,
        "client_id" => "tab-1",
        "chat_id" => 123,
        "visible" => true
      })
      |> json_response(404)

    assert response["error"] == "Subscription not found"
    refute ActiveWebPushClients.active?(user.id, endpoint, 123)
    refute ActiveWebPushClients.active?(owner.id, endpoint, 123)
  end

  test "admin settings endpoints require admin access", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(user.username, password)
      |> get("/api/bff/admin/web-push-settings")
      |> json_response(403)

    assert response["error"] == "Forbidden"
  end

  test "admin can update and regenerate Web Push settings", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})

    show_response =
      conn
      |> sign_in_conn(admin.username, password)
      |> get("/api/bff/admin/web-push-settings")
      |> json_response(200)

    initial_public_key = get_in(show_response, ["settings", "vapid_public_key"])
    assert is_binary(initial_public_key)
    refute Map.has_key?(show_response["settings"], "vapid_private_key")

    update_response =
      conn
      |> recycle()
      |> sign_in_conn(admin.username, password)
      |> patch("/api/bff/admin/web-push-settings", %{
        "enabled" => true,
        "public_origin" => "http://localhost:4000",
        "vapid_subject" => "mailto:admin@example.com"
      })
      |> json_response(200)

    assert get_in(update_response, ["settings", "enabled"]) == true
    assert get_in(update_response, ["settings", "public_origin"]) == "http://localhost:4000"
    assert get_in(update_response, ["settings", "vapid_subject"]) == "mailto:admin@example.com"

    revision = get_in(update_response, ["settings", "key_revision"])

    regenerate_response =
      conn
      |> recycle()
      |> sign_in_conn(admin.username, password)
      |> post("/api/bff/admin/web-push-settings/regenerate-keys", %{})
      |> json_response(200)

    assert get_in(regenerate_response, ["settings", "key_revision"]) == revision + 1
    assert get_in(regenerate_response, ["settings", "vapid_public_key"]) != initial_public_key
    refute Map.has_key?(regenerate_response["settings"], "vapid_private_key")
  end

  defp enable_settings!(admin) do
    {:ok, settings} =
      Notifications.update_admin_settings(
        %{
          enabled: true,
          public_origin: "http://localhost:4000",
          vapid_subject: "mailto:admin@example.com"
        },
        admin
      )

    settings
  end

  defp subscription_payload(endpoint) do
    %{
      "endpoint" => endpoint,
      "keys" => %{
        "p256dh" => "p256dh-key",
        "auth" => "auth-key"
      },
      "key_revision" => 1
    }
  end
end
