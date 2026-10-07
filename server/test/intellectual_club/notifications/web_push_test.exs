defmodule IntellectualClub.Notifications.FakeWebPushSender do
  @moduledoc false

  def send(subscription, payload, settings) do
    test_pid = Application.fetch_env!(:intellectual_club, :web_push_test_pid)
    Kernel.send(test_pid, {:web_push_send, subscription.endpoint, payload, settings.key_revision})

    case Application.get_env(:intellectual_club, :web_push_test_result, :ok) do
      callback when is_function(callback, 0) -> callback.()
      result -> result
    end
  end
end

defmodule IntellectualClub.Notifications.WebPushTest do
  use IntellectualClub.DataCase, async: false

  import ExUnit.CaptureLog

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Notifications
  alias IntellectualClub.Notifications.ActiveWebPushClients
  alias IntellectualClub.Notifications.WebPushGenerationEvent
  alias IntellectualClub.Notifications.WebPushSender
  alias IntellectualClub.Notifications.WebPushSettings
  alias IntellectualClub.Notifications.WebPushSubscription

  require Ash.Query

  # Delivery calls the sender synchronously, so once `deliver_generation_finished/3`
  # or recovery returns, every push it made is already in the test mailbox.

  setup do
    put_app_env(:web_push_sender, IntellectualClub.Notifications.FakeWebPushSender)

    put_app_env(:web_push_test_pid, self())
    delete_app_env(:web_push_test_result)
    put_app_env(:web_push_generation_delivery_delay_ms, 0)
    ActiveWebPushClients.reset()

    on_exit(fn ->
      ActiveWebPushClients.reset()
    end)

    :ok
  end

  test "settings are generated once and admin can regenerate VAPID keys" do
    %{user: admin} = user_fixture(%{is_admin: true})

    config = Notifications.client_config(admin)

    assert config.enabled == false
    assert is_binary(config.vapid_public_key)
    assert config.vapid_public_key != ""
    assert config.key_revision == 1

    assert {:ok, updated} =
             Notifications.update_admin_settings(
               %{
                 enabled: true,
                 public_origin: "http://localhost:4000",
                 vapid_subject: "mailto:admin@example.com"
               },
               admin
             )

    assert updated.enabled == true
    assert updated.public_origin == "http://localhost:4000"
    assert updated.vapid_subject == "mailto:admin@example.com"

    old_public_key = updated.vapid_public_key
    old_revision = updated.key_revision

    assert {:ok, regenerated} = Notifications.regenerate_vapid_keys(admin)
    assert regenerated.key_revision == old_revision + 1
    assert regenerated.vapid_public_key != old_public_key
    refute Map.has_key?(regenerated, :vapid_private_key)
  end

  test "sender requests high urgency and encodes a four-digit chat topic as base64url" do
    old_req_defaults = Req.default_options()
    test_pid = self()
    request_stub = {__MODULE__, :web_push_topic}

    Req.default_options(
      Keyword.merge(old_req_defaults, plug: {Req.Test, request_stub}, retry: false)
    )

    on_exit(fn -> Req.default_options(old_req_defaults) end)

    Req.Test.expect(request_stub, fn conn ->
      Kernel.send(test_pid, {:web_push_topic, Plug.Conn.get_req_header(conn, "topic")})
      Kernel.send(test_pid, {:web_push_urgency, Plug.Conn.get_req_header(conn, "urgency")})
      Plug.Conn.send_resp(conn, 201, "")
    end)

    {vapid_public_key, vapid_private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    {subscriber_public_key, _subscriber_private_key} =
      :crypto.generate_key(:ecdh, :prime256v1)

    settings = %WebPushSettings{
      vapid_public_key: Base.url_encode64(vapid_public_key, padding: false),
      vapid_private_key: Base.url_encode64(vapid_private_key, padding: false),
      vapid_subject: "mailto:admin@example.com"
    }

    subscription = %WebPushSubscription{
      endpoint: "https://web.push.apple.com/test",
      p256dh: Base.url_encode64(subscriber_public_key, padding: false),
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }

    assert :ok = WebPushSender.send(subscription, %{chat_id: 1000}, settings)
    assert_receive {:web_push_topic, ["Y2hhdDoxMDAw"]}
    assert_receive {:web_push_urgency, ["high"]}
  end

  test "users can upsert and delete their own subscriptions" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    assert {:ok, subscription} =
             Notifications.upsert_subscription(
               actor,
               subscription_payload("https://push.example/one"),
               "ua/1"
             )

    assert subscription.owner_id == actor.id
    assert subscription.endpoint == "https://push.example/one"
    assert subscription.p256dh == "p256dh-key"
    assert subscription.auth == "auth-key"

    assert {:ok, updated} =
             Notifications.upsert_subscription(
               actor,
               subscription_payload("https://push.example/one", p256dh: "updated-p256dh"),
               "ua/2"
             )

    assert updated.id == subscription.id
    assert updated.p256dh == "updated-p256dh"
    assert updated.user_agent == "ua/2"

    assert :ok = Notifications.delete_subscription(actor, "https://push.example/one")

    assert [] =
             WebPushSubscription
             |> Ash.Query.filter(owner_id == ^actor.id and endpoint == "https://push.example/one")
             |> Ash.read!(actor: actor)
  end

  describe "device subscriptions" do
    test "re-subscribing a device replaces only that device's previous endpoint" do
      %{user: admin} = user_fixture(%{is_admin: true})
      %{user: actor} = user_fixture()
      %{user: other} = user_fixture()

      _settings = enable_settings!(admin)

      {:ok, stale} =
        Notifications.upsert_subscription(
          actor,
          subscription_payload("https://push.example/stale", device_id: "device-aaaa1111"),
          "ua/stale"
        )

      {:ok, other_device} =
        Notifications.upsert_subscription(
          actor,
          subscription_payload("https://push.example/other-device", device_id: "device-bbbb2222")
        )

      {:ok, legacy} =
        Notifications.upsert_subscription(
          actor,
          subscription_payload("https://push.example/legacy")
        )

      {:ok, other_owner} =
        Notifications.upsert_subscription(
          other,
          subscription_payload("https://push.example/other-owner", device_id: "device-aaaa1111")
        )

      :ok = ActiveWebPushClients.upsert(actor.id, stale.endpoint, "client-1", 10)

      log =
        capture_log(fn ->
          assert {:ok, replacement} =
                   Notifications.upsert_subscription(
                     actor,
                     subscription_payload("https://push.example/fresh",
                       device_id: "device-aaaa1111"
                     )
                   )

          assert replacement.device_id == "device-aaaa1111"
        end)

      assert log =~ "replaced by the same device"
      assert log =~ "subscription_id=#{stale.id}"
      assert log =~ "endpoint_host=push.example"
      refute log =~ "push.example/stale"

      assert {:error, _error} = Ash.get(WebPushSubscription, stale.id, actor: actor)
      refute ActiveWebPushClients.active?(actor.id, stale.endpoint, 10)

      assert {:ok, _subscription} = Ash.get(WebPushSubscription, other_device.id, actor: actor)
      assert {:ok, _subscription} = Ash.get(WebPushSubscription, legacy.id, actor: actor)
      assert {:ok, _subscription} = Ash.get(WebPushSubscription, other_owner.id, actor: other)

      assert [
               "https://push.example/fresh",
               "https://push.example/legacy",
               "https://push.example/other-device"
             ] =
               WebPushSubscription
               |> Ash.Query.filter(owner_id == ^actor.id)
               |> Ash.Query.sort(endpoint: :asc)
               |> Ash.read!(actor: actor)
               |> Enum.map(& &1.endpoint)
    end

    test "an existing endpoint adopts the device id it is synced with" do
      %{user: admin} = user_fixture(%{is_admin: true})
      %{user: actor} = user_fixture()

      _settings = enable_settings!(admin)

      {:ok, subscription} =
        Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

      assert subscription.device_id == nil

      assert {:ok, synced} =
               Notifications.upsert_subscription(
                 actor,
                 subscription_payload("https://push.example/one", device_id: "device-aaaa1111")
               )

      assert synced.id == subscription.id
      assert synced.device_id == "device-aaaa1111"
    end

    test "malformed device ids are rejected" do
      %{user: admin} = user_fixture(%{is_admin: true})
      %{user: actor} = user_fixture()

      _settings = enable_settings!(admin)

      for device_id <- ["short", "has spaces in it", String.duplicate("a", 65), %{"id" => 1}] do
        assert {:error, {:validation, "Subscription device id is invalid."}} =
                 Notifications.upsert_subscription(
                   actor,
                   subscription_payload("https://push.example/one", device_id: device_id)
                 )
      end
    end
  end

  describe "generation payload" do
    test "declarative notification mirrors legacy fields with absolute URLs" do
      %{user: admin} = user_fixture(%{is_admin: true})
      %{user: actor} = user_fixture()
      actor = put_preferred_locale!(actor, "ru")

      _settings = enable_settings!(admin)

      {:ok, _subscription} =
        Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

      message = assistant_message!(actor, "Готовый ответ")
      assert :ok = Notifications.deliver_generation_finished(message.id, :done)

      assert_receive {:web_push_send, "https://push.example/one", payload, 1}

      relative_url = "/chats/#{message.chat_id}?focusMessage=#{message.id}"

      assert payload.web_push == 8030
      assert payload.mutable == true
      assert payload.url == relative_url
      assert payload.title == "Генерация завершена"
      assert payload.body == "Notifications test: Готовый ответ"

      assert payload.notification == %{
               title: "Генерация завершена",
               body: "Notifications test: Готовый ответ",
               lang: "ru",
               navigate: "http://localhost:4000" <> relative_url,
               tag: "chat:#{message.chat_id}",
               icon: "http://localhost:4000/images/pwa/icon-192.png",
               data: %{
                 url: relative_url,
                 chat_id: message.chat_id,
                 message_id: message.id,
                 status: "done"
               }
             }

      decoded = payload |> Jason.encode!() |> Jason.decode!()
      assert decoded["web_push"] == 8030

      assert %URI{scheme: "http", host: "localhost"} =
               URI.parse(decoded["notification"]["navigate"])
    end

    test "payload without a public origin carries only legacy fields" do
      %{user: admin} = user_fixture(%{is_admin: true})
      %{user: actor} = user_fixture()

      _settings = enable_settings!(admin)

      Notifications.ensure_settings!()
      |> Ash.Changeset.for_update(:update_settings, %{public_origin: nil}, actor: admin)
      |> Ash.update!(actor: admin)

      {:ok, _subscription} =
        Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

      message = assistant_message!(actor, "Done answer")
      assert :ok = Notifications.deliver_generation_finished(message.id, :done)

      assert_receive {:web_push_send, "https://push.example/one", payload, 1}
      refute Map.has_key?(payload, :web_push)
      refute Map.has_key?(payload, :notification)
      assert payload.title == "Generation finished"
      assert payload.url == "/chats/#{message.chat_id}?focusMessage=#{message.id}"
    end

    test "oversized notification text is shortened below the push service limit" do
      %{user: admin} = user_fixture(%{is_admin: true})
      %{user: actor} = user_fixture()

      _settings = enable_settings!(admin)

      {:ok, _subscription} =
        Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

      message =
        assistant_message!(actor, String.duplicate("ответ 😀 ", 200),
          note: String.duplicate("Очень длинное название чата ", 200)
        )

      assert :ok = Notifications.deliver_generation_finished(message.id, :done)

      assert_receive {:web_push_send, "https://push.example/one", payload, 1}
      assert byte_size(Jason.encode!(payload)) <= 3_584
      assert String.ends_with?(payload.body, "…")
      assert String.starts_with?(payload.body, "Очень длинное название чата")
      assert payload.notification.body == payload.body
    end
  end

  test "generation notification is idempotent and sends the expected payload" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture(%{preferred_locale: "en"})

    _settings = enable_settings!(admin)

    {:ok, _subscription} =
      Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

    message = assistant_message!(actor, "Done answer")

    assert :ok = Notifications.deliver_generation_finished(message.id, :done)

    assert_receive {:web_push_send, "https://push.example/one", payload, 1}
    assert payload.type == "generation_finished"
    assert payload.status == "done"
    assert payload.chat_id == message.chat_id
    assert payload.message_id == message.id
    assert payload.body == "Notifications test: Done answer"
    assert payload.url == "/chats/#{message.chat_id}?focusMessage=#{message.id}"
    assert payload.tag == "chat:#{message.chat_id}"

    assert [%WebPushGenerationEvent{delivered_count: 1, suppressed: false}] =
             events_for(message.id, :done, actor)

    assert :ok = Notifications.deliver_generation_finished(message.id, :done)
    refute_received {:web_push_send, _, _, _}
    assert [_event] = events_for(message.id, :done, actor)
  end

  test "canceled generation does not send while failed generation does" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture(%{preferred_locale: "en"})

    _settings = enable_settings!(admin)

    {:ok, _subscription} =
      Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

    canceled = assistant_message!(actor, "Canceled answer")

    assert {:ok, %WebPushGenerationEvent{suppressed: true, delivered_count: 0}} =
             Notifications.record_generation_finished(canceled.id, :canceled)

    assert :ok = Notifications.deliver_generation_finished(canceled.id, :canceled)
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{suppressed: true, delivered_count: 0}] =
             events_for(canceled.id, :canceled, actor)

    failed = assistant_message!(actor, "Failed answer")
    assert :ok = Notifications.deliver_generation_finished(failed.id, :error)

    assert_receive {:web_push_send, "https://push.example/one", payload, 1}
    assert payload.status == "error"
    assert payload.message_id == failed.id
    assert payload.title == "Generation failed"
  end

  test "recovery settles legacy pending canceled events without sending" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    {:ok, _subscription} =
      Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

    message = assistant_message!(actor, "Canceled before upgrade")

    WebPushGenerationEvent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_id: message.id,
        status: :canceled,
        suppressed: false,
        delivered_count: -1
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    assert :ok = Notifications.recover_pending_generation_events()
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{suppressed: false, delivered_count: 0}] =
             events_for(message.id, :canceled, actor)
  end

  test "unsuppressed generation event remains pending until delivery starts" do
    %{user: actor} = user_fixture()
    message = assistant_message!(actor, "Pending answer")

    assert {:ok, %WebPushGenerationEvent{} = event} =
             Notifications.record_generation_finished(message.id, :done)

    assert event.suppressed == false
    assert event.delivered_count == -1
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{delivered_count: -1, suppressed: false}] =
             events_for(message.id, :done, actor)
  end

  test "concurrent duplicate delivery dispatches one pending event exactly once" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    {:ok, _subscription} =
      Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

    message = assistant_message!(actor, "Concurrent answer")

    assert {:ok, %WebPushGenerationEvent{delivered_count: -1}} =
             Notifications.record_generation_finished(message.id, :done)

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Notifications.deliver_generation_finished(message.id, :done) end,
        max_concurrency: 2,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert [{:ok, :ok}, {:ok, :ok}] = results
    assert_receive {:web_push_send, "https://push.example/one", payload, 1}
    assert payload.message_id == message.id
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{delivered_count: 1, suppressed: false}] =
             events_for(message.id, :done, actor)
  end

  test "pending generation event is delivered by recovery" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    {:ok, _subscription} =
      Notifications.upsert_subscription(
        actor,
        subscription_payload("https://push.example/recovery")
      )

    message = assistant_message!(actor, "Recovered answer")

    assert {:ok, %WebPushGenerationEvent{delivered_count: -1}} =
             Notifications.record_generation_finished(message.id, :done)

    assert :ok = Notifications.recover_pending_generation_events()

    assert_receive {:web_push_send, "https://push.example/recovery", payload, 1}
    assert payload.message_id == message.id

    assert [%WebPushGenerationEvent{delivered_count: 1, suppressed: false}] =
             events_for(message.id, :done, actor)
  end

  describe "delivery claims" do
    setup do
      %{user: admin} = user_fixture(%{is_admin: true})
      %{user: actor} = user_fixture()
      _settings = enable_settings!(admin)

      {:ok, _subscription} =
        Notifications.upsert_subscription(
          actor,
          subscription_payload("https://push.example/claim")
        )

      message = assistant_message!(actor, "Claimed answer")
      {:ok, event} = Notifications.record_generation_finished(message.id, :done)

      %{actor: actor, message: message, event: event}
    end

    test "duplicate delivery and recovery skip a sender still in flight", %{
      actor: actor,
      message: message
    } do
      parent = self()

      put_app_env(:web_push_test_result, fn ->
        send(parent, {:sender_waiting, self()})

        receive do
          :finish -> :ok
        end
      end)

      supervisor = start_supervised!(Task.Supervisor)

      delivery =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Notifications.deliver_generation_finished(message.id, :done)
        end)

      assert_receive {:sender_waiting, sender}, 5_000
      on_exit(fn -> send(sender, :finish) end)
      assert_receive {:web_push_send, "https://push.example/claim", _payload, 1}

      assert :ok = Notifications.deliver_generation_finished(message.id, :done)
      assert :ok = Notifications.recover_pending_generation_events()
      refute_received {:web_push_send, _, _, _}

      assert [%WebPushGenerationEvent{delivered_count: -1, delivery_token: token}] =
               events_for(message.id, :done, actor)

      assert is_binary(token)
      send(sender, :finish)
      assert :ok = Task.await(delivery, 5_000)

      assert [%WebPushGenerationEvent{delivered_count: 1, delivery_token: nil}] =
               events_for(message.id, :done, actor)
    end

    test "a sender exception releases its claim for recovery", %{actor: actor, message: message} do
      put_app_env(:web_push_test_result, fn -> raise "sender unavailable" end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Notifications.deliver_generation_finished(message.id, :done)
      end)

      assert_receive {:web_push_send, "https://push.example/claim", _payload, 1}

      assert [%WebPushGenerationEvent{delivered_count: -1, delivery_token: nil}] =
               events_for(message.id, :done, actor)

      put_app_env(:web_push_test_result, :ok)
      assert :ok = Notifications.recover_pending_generation_events()
      assert_receive {:web_push_send, "https://push.example/claim", _payload, 1}

      assert [%WebPushGenerationEvent{delivered_count: 1, delivery_token: nil}] =
               events_for(message.id, :done, actor)
    end

    test "a timed out sender is stopped and its expired claim can be recovered", %{
      actor: actor,
      message: message
    } do
      parent = self()
      put_app_env(:web_push_generation_delivery_timeout_ms, 1_000)

      put_app_env(:web_push_test_result, fn ->
        send(parent, {:sender_waiting, self()})

        receive do
          :finish -> :ok
        end
      end)

      supervisor = start_supervised!(Task.Supervisor)

      ExUnit.CaptureLog.capture_log(fn ->
        delivery =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Notifications.deliver_generation_finished(message.id, :done)
          end)

        assert_receive {:sender_waiting, sender}, 5_000
        monitor = Process.monitor(sender)
        assert :ok = Task.await(delivery, 5_000)
        assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}
      end)

      assert_receive {:web_push_send, "https://push.example/claim", _payload, 1}
      assert [event] = events_for(message.id, :done, actor)
      assert event.delivered_count == -1
      assert is_binary(event.delivery_token)

      assert :ok = Notifications.recover_pending_generation_events()
      refute_received {:web_push_send, _, _, _}

      event
      |> Ash.Changeset.for_update(
        :claim_delivery,
        %{delivery_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      put_app_env(:web_push_test_result, :ok)
      assert :ok = Notifications.recover_pending_generation_events()
      assert_receive {:web_push_send, "https://push.example/claim", _payload, 1}

      assert [%WebPushGenerationEvent{delivered_count: 1, delivery_token: nil}] =
               events_for(message.id, :done, actor)
    end

    test "an old sender cannot acknowledge or release a replacement claim", %{
      actor: actor,
      message: message,
      event: event
    } do
      parent = self()

      put_app_env(:web_push_test_result, fn ->
        send(parent, {:sender_waiting, self()})

        receive do
          :finish -> :ok
        end
      end)

      supervisor = start_supervised!(Task.Supervisor)

      delivery =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Notifications.deliver_generation_finished(message.id, :done)
        end)

      assert_receive {:sender_waiting, sender}, 5_000
      on_exit(fn -> send(sender, :finish) end)
      replacement_token = Ash.UUID.generate()

      event
      |> Ash.Changeset.for_update(
        :claim_delivery,
        %{
          delivery_token: replacement_token,
          delivery_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        },
        actor: actor
      )
      |> Ash.update!(actor: actor)

      send(sender, :finish)
      assert :ok = Task.await(delivery, 5_000)

      assert [%WebPushGenerationEvent{delivered_count: -1, delivery_token: ^replacement_token}] =
               events_for(message.id, :done, actor)
    end
  end

  describe "delivery across database sessions" do
    @describetag :whitebox
    @describetag sandbox: false

    test "a blocked sender holds neither a transaction nor an event row lock" do
      %{user: admin} = user_fixture(%{is_admin: true})
      %{user: actor} = user_fixture()
      original_settings = Ash.read_one!(WebPushSettings, authorize?: false)
      _settings = enable_settings!(admin)
      settings = Notifications.ensure_settings!()
      endpoint = "https://push.example/row-lock"

      {:ok, _subscription} =
        Notifications.upsert_subscription(actor, subscription_payload(endpoint))

      message = assistant_message!(actor, "Unlocked answer")
      {:ok, event} = Notifications.record_generation_finished(message.id, :done)

      on_exit(fn ->
        IntellectualClub.DataCase.stop_background_test_tasks()

        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          :ok = Notifications.delete_subscription(actor, endpoint)
          Ash.destroy!(Ash.get!(Chat, message.chat_id, actor: actor), actor: actor)

          if original_settings do
            Notifications.ensure_settings!()
            |> Ash.Changeset.for_update(
              :update_settings,
              Map.take(original_settings, [:enabled, :public_origin, :vapid_subject]),
              actor: admin
            )
            |> Ash.update!(actor: admin)
          else
            # The singleton has no destroy action; remove only this test's committed fixture.
            Repo.delete_all(from(s in WebPushSettings, where: s.id == ^settings.id))
          end

          Enum.each([actor, admin], fn user ->
            user
            |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
            |> Ash.destroy!(authorize?: false)
          end)
        end)
      end)

      parent = self()

      put_app_env(:web_push_test_result, fn ->
        send(parent, {:sender_waiting, self(), backend_pid!(), Repo.in_transaction?()})

        receive do
          :finish -> :ok
        end
      end)

      supervisor = start_supervised!(Task.Supervisor)

      delivery =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Notifications.deliver_generation_finished(message.id, :done)
        end)

      assert_receive {:sender_waiting, sender, sender_backend, in_transaction?}, 5_000
      on_exit(fn -> send(sender, :finish) end)
      refute in_transaction?

      assert {:ok, %WebPushGenerationEvent{id: id}} =
               Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                 assert sender_backend != backend_pid!()

                 Ash.transaction(WebPushGenerationEvent, fn ->
                   WebPushGenerationEvent
                   |> Ash.Query.filter(id == ^event.id)
                   |> Ash.Query.lock("FOR NO KEY UPDATE")
                   |> Ash.read_one!(actor: actor, timeout: 1_000)
                 end)
               end)

      assert id == event.id
      send(sender, :finish)
      assert :ok = Task.await(delivery, 5_000)

      assert [%WebPushGenerationEvent{delivered_count: 1, delivery_token: nil}] =
               events_for(message.id, :done, actor)
    end
  end

  test "recovery preserves the notification grace window for fresh events" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    {:ok, _subscription} =
      Notifications.upsert_subscription(
        actor,
        subscription_payload("https://push.example/grace-window")
      )

    put_app_env(:web_push_generation_delivery_delay_ms, 5_000)
    message = assistant_message!(actor, "Fresh pending answer")

    assert {:ok, %WebPushGenerationEvent{delivered_count: -1}} =
             Notifications.record_generation_finished(message.id, :done)

    assert :ok = Notifications.recover_pending_generation_events()
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{delivered_count: -1, suppressed: false}] =
             events_for(message.id, :done, actor)
  end

  test "expired subscriptions are pruned without failing notification delivery" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    {:ok, subscription} =
      Notifications.upsert_subscription(
        actor,
        subscription_payload("https://push.example/expired")
      )

    put_app_env(:web_push_test_result, {:error, :expired})

    message = assistant_message!(actor, "Done answer")

    log =
      capture_log(fn ->
        assert :ok = Notifications.deliver_generation_finished(message.id, :done)
      end)

    assert_receive {:web_push_send, "https://push.example/expired", _payload, 1}

    assert log =~ "Web push subscription expired"
    assert log =~ "subscription_id=#{subscription.id}"
    assert log =~ "owner_id=#{actor.id}"
    assert log =~ "endpoint_host=push.example"
    refute log =~ "push.example/expired"

    assert {:error, _error} = Ash.get(WebPushSubscription, subscription.id, actor: actor)
  end

  test "suppressed handoff parent does not send while final child generation does" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    {:ok, _subscription} =
      Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

    parent = assistant_message!(actor, "Continuing in another chat")

    assert :ok = Notifications.suppress_generation_finished(parent.id, :done)
    assert :ok = Notifications.deliver_generation_finished(parent.id, :done)
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{suppressed: true, delivered_count: 0}] =
             events_for(parent.id, :done, actor)

    child = assistant_message!(actor, "Final child answer")
    assert :ok = Notifications.deliver_generation_finished(child.id, :done)
    assert_receive {:web_push_send, "https://push.example/one", payload, 1}
    assert payload.message_id == child.id
  end

  test "fork subagent generations do not send notifications" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    {:ok, _subscription} =
      Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

    parent_message = assistant_message!(actor, "Parent answer")

    subchat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "Fork subagent",
          parent_chat_id: parent_message.chat_id,
          parent_relation_kind: :fork,
          subagent: true
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    message = assistant_message_for_chat!(actor, subchat.id, "Subagent answer")

    assert :ok = Notifications.deliver_generation_finished(message.id, :done)
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{suppressed: true, delivered_count: 0}] =
             events_for(message.id, :done, actor)
  end

  test "active visible client suppresses only matching chat subscriptions" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)
    endpoint = "https://push.example/one"

    {:ok, _subscription} =
      Notifications.upsert_subscription(actor, subscription_payload(endpoint))

    message = assistant_message!(actor, "Visible answer")
    assert :ok = ActiveWebPushClients.upsert(actor.id, endpoint, "client-a", message.chat_id)

    assert :ok = Notifications.deliver_generation_finished(message.id, :done)
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{delivered_count: 0, suppressed: false}] =
             events_for(message.id, :done, actor)

    other_message = assistant_message!(actor, "Other chat answer")
    assert :ok = Notifications.deliver_generation_finished(other_message.id, :done)
    assert_receive {:web_push_send, ^endpoint, other_payload, 1}
    assert other_payload.chat_id == other_message.chat_id

    assert :ok = ActiveWebPushClients.remove(endpoint, "client-a")

    follow_up = assistant_message_for_chat!(actor, message.chat_id, "Later answer")
    assert :ok = Notifications.deliver_generation_finished(follow_up.id, :done)
    assert_receive {:web_push_send, ^endpoint, follow_up_payload, 1}
    assert follow_up_payload.chat_id == message.chat_id
    assert follow_up_payload.tag == "chat:#{message.chat_id}"
  end

  test "periodic pruning keeps clients and seen generations that are still fresh" do
    owner_id = System.unique_integer([:positive])
    endpoint = "https://push.example/fresh"

    assert :ok = ActiveWebPushClients.upsert(owner_id, endpoint, "client-a", 7)
    assert :ok = ActiveWebPushClients.record_generation_seen(owner_id, 7, 70, :done)

    # The periodic sweep runs every 15 s; trigger it now. Later calls are
    # handled by the same process after it.
    send(ActiveWebPushClients, :prune)

    assert ActiveWebPushClients.active?(owner_id, endpoint, 7)
    assert ActiveWebPushClients.generation_seen?(owner_id, 7, 70, :done)
  end

  test "generation seen during delivery delay suppresses all device notifications" do
    %{user: admin} = user_fixture(%{is_admin: true})
    %{user: actor} = user_fixture()

    _settings = enable_settings!(admin)

    {:ok, _first_subscription} =
      Notifications.upsert_subscription(actor, subscription_payload("https://push.example/one"))

    {:ok, _second_subscription} =
      Notifications.upsert_subscription(actor, subscription_payload("https://push.example/two"))

    message = assistant_message!(actor, "Seen before push")

    task =
      Task.async(fn ->
        Notifications.deliver_generation_finished(message.id, :done, delay_ms: 75)
      end)

    # Mark the generation as seen once its event is recorded, while delivery waits.
    wait_until(fn -> events_for(message.id, :done, actor) != [] end, interval: 2)

    assert :ok =
             ActiveWebPushClients.record_generation_seen(
               actor.id,
               message.chat_id,
               message.id,
               :done
             )

    assert :ok = Task.await(task)
    refute_received {:web_push_send, _, _, _}

    assert [%WebPushGenerationEvent{delivered_count: 0, suppressed: false}] =
             events_for(message.id, :done, actor)
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

  defp put_preferred_locale!(user, locale) do
    user
    |> Ash.Changeset.for_update(:update_settings, %{preferred_locale: locale}, actor: user)
    |> Ash.update!(actor: user)
  end

  defp subscription_payload(endpoint, opts \\ []) do
    %{
      endpoint: endpoint,
      keys: %{
        p256dh: Keyword.get(opts, :p256dh, "p256dh-key"),
        auth: Keyword.get(opts, :auth, "auth-key")
      },
      key_revision: Keyword.get(opts, :key_revision, 1),
      device_id: Keyword.get(opts, :device_id)
    }
  end

  defp assistant_message!(actor, text, opts \\ []) do
    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: Keyword.get(opts, :note, "Notifications test")},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)
    {:ok, assistant_message} = Threads.add_message_to_end(chat, :assistant, text, actor: actor)
    assistant_message
  end

  defp assistant_message_for_chat!(actor, chat_id, text) do
    chat = Ash.get!(Chat, chat_id, actor: actor)
    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "Follow-up", actor: actor)
    {:ok, assistant_message} = Threads.add_message_to_end(chat, :assistant, text, actor: actor)
    assistant_message
  end

  defp events_for(message_id, status, actor) do
    WebPushGenerationEvent
    |> Ash.Query.filter(chat_message_id == ^message_id and status == ^status)
    |> Ash.read!(actor: actor)
  end
end
