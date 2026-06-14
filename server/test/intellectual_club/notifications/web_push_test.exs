defmodule IntellectualClub.Notifications.FakeWebPushSender do
  @moduledoc false

  def send(subscription, payload, settings) do
    test_pid = Application.fetch_env!(:intellectual_club, :web_push_test_pid)
    Kernel.send(test_pid, {:web_push_send, subscription.endpoint, payload, settings.key_revision})
    Application.get_env(:intellectual_club, :web_push_test_result, :ok)
  end
end

defmodule IntellectualClub.Notifications.WebPushTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Notifications
  alias IntellectualClub.Notifications.WebPushGenerationEvent
  alias IntellectualClub.Notifications.WebPushSubscription

  require Ash.Query

  setup do
    old_sender = Application.get_env(:intellectual_club, :web_push_sender)
    old_test_pid = Application.get_env(:intellectual_club, :web_push_test_pid)
    old_test_result = Application.get_env(:intellectual_club, :web_push_test_result)

    Application.put_env(
      :intellectual_club,
      :web_push_sender,
      IntellectualClub.Notifications.FakeWebPushSender
    )

    Application.put_env(:intellectual_club, :web_push_test_pid, self())
    Application.delete_env(:intellectual_club, :web_push_test_result)

    on_exit(fn ->
      restore_env(:web_push_sender, old_sender)
      restore_env(:web_push_test_pid, old_test_pid)
      restore_env(:web_push_test_result, old_test_result)
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
    assert payload.tag == "generation:#{message.id}"

    assert [%WebPushGenerationEvent{delivered_count: 1, suppressed: false}] =
             events_for(message.id, :done, actor)

    assert :ok = Notifications.deliver_generation_finished(message.id, :done)
    refute_receive {:web_push_send, _, _, _}, 100
    assert [_event] = events_for(message.id, :done, actor)
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

    Application.put_env(:intellectual_club, :web_push_test_result, {:error, :expired})

    message = assistant_message!(actor, "Done answer")
    assert :ok = Notifications.deliver_generation_finished(message.id, :done)

    assert_receive {:web_push_send, "https://push.example/expired", _payload, 1}

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
    refute_receive {:web_push_send, _, _, _}, 100

    assert [%WebPushGenerationEvent{suppressed: true, delivered_count: 0}] =
             events_for(parent.id, :done, actor)

    child = assistant_message!(actor, "Final child answer")
    assert :ok = Notifications.deliver_generation_finished(child.id, :done)
    assert_receive {:web_push_send, "https://push.example/one", payload, 1}
    assert payload.message_id == child.id
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)

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

  defp subscription_payload(endpoint, opts \\ []) do
    %{
      endpoint: endpoint,
      keys: %{
        p256dh: Keyword.get(opts, :p256dh, "p256dh-key"),
        auth: Keyword.get(opts, :auth, "auth-key")
      },
      key_revision: Keyword.get(opts, :key_revision, 1)
    }
  end

  defp assistant_message!(actor, text) do
    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "Notifications test"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)
    {:ok, assistant_message} = Threads.add_message_to_end(chat, :assistant, text, actor: actor)
    assistant_message
  end

  defp events_for(message_id, status, actor) do
    WebPushGenerationEvent
    |> Ash.Query.filter(chat_message_id == ^message_id and status == ^status)
    |> Ash.read!(actor: actor)
  end
end
