defmodule IntellectualClub.Notifications do
  @moduledoc """
  Notifications domain and Web Push service entry points.
  """

  use Ash.Domain

  require Ash.Query
  require Logger

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Notifications.ActiveWebPushClients
  alias IntellectualClub.Notifications.WebPushGenerationEvent
  alias IntellectualClub.Notifications.WebPushSender
  alias IntellectualClub.Notifications.WebPushSettings
  alias IntellectualClub.Notifications.WebPushSubscription
  alias IntellectualClubWeb.Bff.Serializer

  @singleton_key "default"
  @default_vapid_subject "mailto:admin@example.com"
  @notification_body_preview_length 180

  resources do
    resource(WebPushSettings)
    resource(WebPushSubscription)
    resource(WebPushGenerationEvent)
  end

  @spec client_config(map()) :: map()
  def client_config(_actor) do
    settings = ensure_settings!()

    %{
      enabled: settings.enabled,
      public_origin: settings.public_origin,
      vapid_public_key: settings.vapid_public_key,
      key_revision: settings.key_revision
    }
  end

  @spec admin_settings(map()) :: map()
  def admin_settings(actor) do
    _ = require_admin!(actor)
    ensure_settings!() |> serialize_admin_settings()
  end

  @spec update_admin_settings(map(), map()) :: {:ok, map()} | {:error, term()}
  def update_admin_settings(params, actor) when is_map(params) do
    _ = require_admin!(actor)

    with {:ok, payload} <- settings_payload(params),
         :ok <- validate_settings_payload(payload) do
      ensure_settings!()
      |> Ash.Changeset.for_update(:update_settings, payload, actor: actor)
      |> Ash.update()
      |> case do
        {:ok, settings} -> {:ok, serialize_admin_settings(settings)}
        {:error, error} -> {:error, error}
      end
    end
  end

  @spec regenerate_vapid_keys(map()) :: {:ok, map()} | {:error, term()}
  def regenerate_vapid_keys(actor) do
    _ = require_admin!(actor)

    settings = ensure_settings!()
    keys = generate_vapid_keys()

    payload = %{
      vapid_public_key: keys.public_key,
      vapid_private_key: keys.private_key,
      key_revision: settings.key_revision + 1
    }

    settings
    |> Ash.Changeset.for_update(:regenerate_keys, payload, actor: actor)
    |> Ash.update()
    |> case do
      {:ok, settings} -> {:ok, serialize_admin_settings(settings)}
      {:error, error} -> {:error, error}
    end
  end

  @spec upsert_subscription(map(), map(), String.t() | nil) ::
          {:ok, WebPushSubscription.t()} | {:error, term()}
  def upsert_subscription(actor, params, user_agent \\ nil) when is_map(params) do
    settings = ensure_settings!()

    with true <- settings.enabled || {:error, :web_push_disabled},
         {:ok, payload} <- subscription_payload(params, settings, user_agent),
         :ok <- validate_subscription_payload(payload) do
      case find_subscription(payload.endpoint, actor) do
        {:ok, %WebPushSubscription{} = subscription} ->
          subscription
          |> Ash.Changeset.for_update(:update, Map.delete(payload, :endpoint), actor: actor)
          |> Ash.update()

        {:ok, nil} ->
          WebPushSubscription
          |> Ash.Changeset.for_create(:create, payload, actor: actor)
          |> Ash.create()

        {:error, error} ->
          {:error, error}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete_subscription(map(), String.t()) :: :ok | {:error, term()}
  def delete_subscription(actor, endpoint) when is_binary(endpoint) do
    endpoint = String.trim(endpoint)

    if endpoint == "" do
      :ok
    else
      case find_subscription(endpoint, actor) do
        {:ok, %WebPushSubscription{} = subscription} ->
          destroy_subscription(subscription, actor)

        {:ok, nil} ->
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def delete_subscription(_actor, _endpoint), do: :ok

  @spec record_client_state(map(), map()) :: :ok | {:error, term()}
  def record_client_state(actor, params) when is_map(params) do
    with {:ok, payload} <- client_state_payload(params),
         :ok <- validate_client_state_payload(payload),
         {:ok, %WebPushSubscription{}} <- find_subscription(payload.endpoint, actor) do
      if payload.visible do
        ActiveWebPushClients.upsert(
          actor.id,
          payload.endpoint,
          payload.client_id,
          payload.chat_id
        )
      else
        ActiveWebPushClients.remove(payload.endpoint, payload.client_id)
      end
    else
      {:ok, nil} -> {:error, :subscription_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_client_state(_actor, _params), do: {:error, {:validation, "Invalid client state."}}

  @spec deliver_generation_finished(integer(), :done | :error, keyword()) :: :ok
  def deliver_generation_finished(message_id, status, opts \\ [])

  def deliver_generation_finished(message_id, status, opts)
      when is_integer(message_id) and status in [:done, :error] and is_list(opts) do
    message = load_message_for_notification(message_id)
    actor = %User{id: message.owner_id}

    case create_generation_event(message, status, actor, Keyword.get(opts, :suppressed?, false)) do
      {:ok, %WebPushGenerationEvent{suppressed: true}} ->
        :ok

      {:ok, %WebPushGenerationEvent{} = event} ->
        dispatch_generation_event(event, message, status, actor)

      {:duplicate, _event} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "Failed to create web push generation event message_id=#{message_id} status=#{status}: #{inspect(error)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to dispatch web push generation notification message_id=#{message_id} status=#{status}: #{Exception.message(exception)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "Web push generation notification exited message_id=#{message_id} status=#{status}: #{inspect(reason)}"
      )

      :ok
  end

  def deliver_generation_finished(_message_id, _status, _opts), do: :ok

  @spec suppress_generation_finished(integer(), :done | :error) :: :ok
  def suppress_generation_finished(message_id, status)
      when is_integer(message_id) and status in [:done, :error] do
    deliver_generation_finished(message_id, status, suppressed?: true)
  end

  def suppress_generation_finished(_message_id, _status), do: :ok

  @spec ensure_settings!() :: WebPushSettings.t()
  def ensure_settings! do
    case fetch_settings() do
      %WebPushSettings{} = settings ->
        settings

      nil ->
        create_default_settings()
    end
  end

  defp dispatch_generation_event(event, message, status, actor) do
    settings = ensure_settings!()

    if settings.enabled do
      subscriptions = list_current_subscriptions(actor, settings.key_revision)
      payload = generation_payload(message, status)

      delivered_count =
        subscriptions
        |> Enum.map(&maybe_send_generation_payload(&1, payload, settings, actor, message.chat_id))
        |> Enum.count(&(&1 == :ok))

      mark_event_delivered(event, delivered_count, actor)
    end

    :ok
  end

  defp maybe_send_generation_payload(subscription, payload, settings, actor, chat_id) do
    if ActiveWebPushClients.active?(actor.id, subscription.endpoint, chat_id) do
      :active_client
    else
      send_generation_payload(subscription, payload, settings, actor)
    end
  end

  defp send_generation_payload(subscription, payload, settings, actor) do
    case sender().send(subscription, payload, settings) do
      :ok ->
        :ok

      {:error, :expired} ->
        _ = destroy_subscription(subscription, actor)
        :expired

      {:error, reason} ->
        Logger.warning(
          "Web push send failed subscription_id=#{subscription.id} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp mark_event_delivered(event, delivered_count, actor) when is_integer(delivered_count) do
    event
    |> Ash.Changeset.for_update(:mark_delivered, %{delivered_count: delivered_count},
      actor: actor
    )
    |> Ash.update()
    |> case do
      {:ok, _event} ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to update web push event delivery count: #{inspect(error)}")
        :ok
    end
  end

  defp sender do
    Application.get_env(:intellectual_club, :web_push_sender, WebPushSender)
  end

  defp fetch_settings do
    WebPushSettings
    |> Ash.Query.filter(singleton_key == ^@singleton_key)
    |> Ash.read_one!(authorize?: false)
  end

  defp create_default_settings do
    keys = generate_vapid_keys()
    public_origin = default_public_origin()

    payload = %{
      singleton_key: @singleton_key,
      enabled: false,
      public_origin: public_origin,
      vapid_subject: default_vapid_subject(public_origin),
      vapid_public_key: keys.public_key,
      vapid_private_key: keys.private_key,
      key_revision: 1
    }

    WebPushSettings
    |> Ash.Changeset.for_create(:create, payload, authorize?: false)
    |> Ash.create!(authorize?: false)
  rescue
    _exception ->
      case fetch_settings() do
        %WebPushSettings{} = settings -> settings
        nil -> reraise "failed to create web push settings", __STACKTRACE__
      end
  end

  defp generate_vapid_keys do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      public_key: Base.url_encode64(public_key, padding: false),
      private_key: Base.url_encode64(private_key, padding: false)
    }
  end

  defp default_public_origin do
    endpoint_config = Application.get_env(:intellectual_club, IntellectualClubWeb.Endpoint, [])
    url_config = Keyword.get(endpoint_config, :url, [])
    host = Keyword.get(url_config, :host)
    scheme = Keyword.get(url_config, :scheme, "http")
    port = Keyword.get(url_config, :port)

    cond do
      is_binary(host) and host != "" and is_integer(port) and port not in [80, 443] ->
        "#{scheme}://#{host}:#{port}"

      is_binary(host) and host != "" ->
        "#{scheme}://#{host}"

      true ->
        nil
    end
  end

  defp default_vapid_subject(public_origin)
       when is_binary(public_origin) and public_origin != "" do
    uri = URI.parse(public_origin)

    if uri.scheme == "https" do
      public_origin
    else
      @default_vapid_subject
    end
  end

  defp default_vapid_subject(_public_origin), do: @default_vapid_subject

  defp settings_payload(params) do
    enabled = parse_boolean(Map.get(params, "enabled", Map.get(params, :enabled)), false)

    payload = %{
      enabled: enabled,
      public_origin:
        normalize_optional_string(
          Map.get(params, "public_origin", Map.get(params, :public_origin))
        ),
      vapid_subject:
        normalize_optional_string(
          Map.get(params, "vapid_subject", Map.get(params, :vapid_subject))
        )
    }

    {:ok, payload}
  end

  defp validate_settings_payload(%{enabled: true, public_origin: nil}),
    do: {:error, {:validation, "Public origin is required when Web Push is enabled."}}

  defp validate_settings_payload(%{enabled: true, vapid_subject: nil}),
    do: {:error, {:validation, "VAPID subject is required when Web Push is enabled."}}

  defp validate_settings_payload(%{public_origin: origin, vapid_subject: subject}) do
    with :ok <- validate_public_origin(origin),
         :ok <- validate_vapid_subject(subject) do
      :ok
    end
  end

  defp validate_public_origin(nil), do: :ok

  defp validate_public_origin(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    cond do
      uri.scheme == "https" and valid_origin_uri?(uri) ->
        :ok

      uri.scheme == "http" and valid_origin_uri?(uri) and local_host?(uri.host) ->
        :ok

      true ->
        {:error, {:validation, "Public origin must be an https origin, or localhost over http."}}
    end
  end

  defp validate_vapid_subject(nil), do: :ok

  defp validate_vapid_subject("mailto:" <> rest) do
    if String.trim(rest) == "" do
      {:error, {:validation, "VAPID subject mailto address cannot be empty."}}
    else
      :ok
    end
  end

  defp validate_vapid_subject(subject) when is_binary(subject) do
    uri = URI.parse(subject)

    if uri.scheme == "https" and valid_origin_uri?(uri) do
      :ok
    else
      {:error, {:validation, "VAPID subject must be a mailto or https URL."}}
    end
  end

  defp valid_origin_uri?(%URI{host: host, path: path, query: query, fragment: fragment})
       when is_binary(host) and host != "" do
    path in [nil, ""] and is_nil(query) and is_nil(fragment)
  end

  defp valid_origin_uri?(_uri), do: false

  defp local_host?(host), do: host in ["localhost", "127.0.0.1", "::1"]

  defp subscription_payload(params, settings, user_agent) do
    keys = Map.get(params, "keys", Map.get(params, :keys, %{}))

    payload = %{
      endpoint:
        normalize_required_string(Map.get(params, "endpoint", Map.get(params, :endpoint))),
      p256dh: normalize_required_string(Map.get(keys, "p256dh", Map.get(keys, :p256dh))),
      auth: normalize_required_string(Map.get(keys, "auth", Map.get(keys, :auth))),
      user_agent: normalize_optional_string(user_agent),
      key_revision:
        parse_positive_integer(
          Map.get(params, "key_revision", Map.get(params, :key_revision)),
          settings.key_revision
        ),
      expiration_time:
        parse_optional_non_negative_integer(
          Map.get(params, "expirationTime", Map.get(params, :expiration_time))
        ),
      last_seen_at: DateTime.utc_now()
    }

    {:ok, payload}
  end

  defp validate_subscription_payload(%{endpoint: "", p256dh: _, auth: _}),
    do: {:error, {:validation, "Subscription endpoint is required."}}

  defp validate_subscription_payload(%{endpoint: _, p256dh: "", auth: _}),
    do: {:error, {:validation, "Subscription p256dh key is required."}}

  defp validate_subscription_payload(%{endpoint: _, p256dh: _, auth: ""}),
    do: {:error, {:validation, "Subscription auth key is required."}}

  defp validate_subscription_payload(%{endpoint: endpoint}) do
    uri = URI.parse(endpoint)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, {:validation, "Subscription endpoint must be an https URL."}}
    end
  end

  defp client_state_payload(params) do
    payload = %{
      endpoint:
        normalize_required_string(Map.get(params, "endpoint", Map.get(params, :endpoint))),
      client_id:
        normalize_required_string(Map.get(params, "client_id", Map.get(params, :client_id))),
      chat_id:
        parse_optional_positive_integer(Map.get(params, "chat_id", Map.get(params, :chat_id))),
      visible: parse_boolean(Map.get(params, "visible", Map.get(params, :visible)), false)
    }

    {:ok, payload}
  end

  defp validate_client_state_payload(%{endpoint: ""}),
    do: {:error, {:validation, "Subscription endpoint is required."}}

  defp validate_client_state_payload(%{client_id: ""}),
    do: {:error, {:validation, "Client id is required."}}

  defp validate_client_state_payload(%{visible: true, chat_id: nil}),
    do: {:error, {:validation, "Chat id is required for visible client state."}}

  defp validate_client_state_payload(%{endpoint: endpoint}) do
    uri = URI.parse(endpoint)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, {:validation, "Subscription endpoint must be an https URL."}}
    end
  end

  defp find_subscription(endpoint, actor) do
    WebPushSubscription
    |> Ash.Query.filter(owner_id == ^actor.id and endpoint == ^endpoint)
    |> Ash.read_one(actor: actor)
  end

  defp list_current_subscriptions(actor, key_revision) do
    WebPushSubscription
    |> Ash.Query.filter(owner_id == ^actor.id and key_revision == ^key_revision)
    |> Ash.Query.sort(last_seen_at: :desc, id: :desc)
    |> Ash.read!(actor: actor)
  end

  defp destroy_subscription(subscription, actor) do
    case Ash.destroy(subscription, actor: actor) do
      :ok ->
        ActiveWebPushClients.remove_endpoint(subscription.endpoint)
        :ok

      {:ok, _destroyed} ->
        ActiveWebPushClients.remove_endpoint(subscription.endpoint)
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_generation_event(message, status, actor, suppressed?) do
    case find_generation_event(message.id, status, actor) do
      %WebPushGenerationEvent{} = event ->
        {:duplicate, event}

      nil ->
        WebPushGenerationEvent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_id: message.id,
            status: status,
            suppressed: suppressed? == true,
            delivered_count: 0
          },
          actor: actor
        )
        |> Ash.create()
        |> case do
          {:ok, event} -> {:ok, event}
          {:error, error} -> maybe_duplicate_generation_event(error, message.id, status, actor)
        end
    end
  end

  defp maybe_duplicate_generation_event(error, message_id, status, actor) do
    case find_generation_event(message_id, status, actor) do
      %WebPushGenerationEvent{} = event -> {:duplicate, event}
      nil -> {:error, error}
    end
  end

  defp find_generation_event(message_id, status, actor) do
    WebPushGenerationEvent
    |> Ash.Query.filter(chat_message_id == ^message_id and status == ^status)
    |> Ash.read_one!(actor: actor)
  end

  defp load_message_for_notification(message_id) do
    Ash.get!(ChatMessage, message_id,
      authorize?: false,
      load: [:chat, :owner, steps: [items: [:contents]]]
    )
  end

  defp generation_payload(%ChatMessage{} = message, status) do
    locale = preferred_locale(message)
    chat_id = message.chat_id
    message_id = message.id

    %{
      type: "generation_finished",
      status: Atom.to_string(status),
      chat_id: chat_id,
      message_id: message_id,
      title: notification_title(status, locale),
      body: notification_body(message, status, locale),
      url: "/chats/#{chat_id}?focusMessage=#{message_id}",
      tag: "chat:#{chat_id}"
    }
  end

  defp preferred_locale(%{owner: %User{preferred_locale: locale}}) when locale in ["en", "ru"],
    do: locale

  defp preferred_locale(_message), do: "en"

  defp notification_title(:done, "ru"), do: "Генерация завершена"
  defp notification_title(:error, "ru"), do: "Ошибка генерации"
  defp notification_title(:done, _locale), do: "Generation finished"
  defp notification_title(:error, _locale), do: "Generation failed"

  defp notification_body(%ChatMessage{} = message, _status, _locale) do
    [chat_label(message), answer_preview(message)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(": ")
    |> case do
      "" -> fallback_notification_body(message)
      body -> body
    end
  end

  defp chat_label(%{chat: %{note: note}}), do: normalize_notification_text(note)
  defp chat_label(_message), do: ""

  defp answer_preview(%{steps: steps}) when is_list(steps) do
    steps
    |> Enum.sort_by(&(&1.sequence || 0), :desc)
    |> Enum.flat_map(fn step ->
      step.items
      |> List.wrap()
      |> Enum.filter(&(&1.type == :answer))
      |> Enum.sort_by(&(&1.sequence || 0), :desc)
    end)
    |> Enum.find_value("", &answer_item_text/1)
    |> truncate_notification_text(@notification_body_preview_length)
  end

  defp answer_preview(_message), do: ""

  defp answer_item_text(%{contents: contents}) when is_list(contents) do
    contents
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(&(&1.sequence || 0))
    |> Enum.map_join("", &(&1.content_text || ""))
    |> normalize_notification_text()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp answer_item_text(_item), do: nil

  defp fallback_notification_body(%{status: :error}), do: "Generation failed."
  defp fallback_notification_body(_message), do: "Generation finished."

  defp normalize_notification_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  defp normalize_notification_text(_value), do: ""

  defp truncate_notification_text(text, max_length)
       when is_binary(text) and is_integer(max_length) and max_length > 1 do
    if String.length(text) <= max_length do
      text
    else
      text
      |> String.slice(0, max_length - 1)
      |> String.trim_trailing()
      |> Kernel.<>("…")
    end
  end

  defp serialize_admin_settings(%WebPushSettings{} = settings) do
    %{
      enabled: settings.enabled,
      public_origin: settings.public_origin,
      vapid_subject: settings.vapid_subject,
      vapid_public_key: settings.vapid_public_key,
      key_revision: settings.key_revision,
      created_at: Serializer.datetime_iso(settings.created_at),
      updated_at: Serializer.datetime_iso(settings.updated_at)
    }
  end

  defp require_admin!(%{is_admin: true} = actor), do: actor
  defp require_admin!(_actor), do: raise(Ash.Error.Forbidden.exception([]))

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: value |> to_string() |> normalize_optional_string()

  defp normalize_required_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_required_string(nil), do: ""
  defp normalize_required_string(value), do: value |> to_string() |> normalize_required_string()

  defp parse_boolean(value, _default) when is_boolean(value), do: value
  defp parse_boolean(nil, default), do: default

  defp parse_boolean(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> true
      "1" -> true
      "false" -> false
      "0" -> false
      _other -> default
    end
  end

  defp parse_boolean(_value, default), do: default

  defp parse_positive_integer(value, default) do
    case parse_integer(value) do
      parsed when is_integer(parsed) and parsed > 0 -> parsed
      _other -> default
    end
  end

  defp parse_optional_positive_integer(nil), do: nil

  defp parse_optional_positive_integer(value) do
    case parse_integer(value) do
      parsed when is_integer(parsed) and parsed > 0 -> parsed
      _other -> nil
    end
  end

  defp parse_optional_non_negative_integer(nil), do: nil

  defp parse_optional_non_negative_integer(value) do
    case parse_integer(value) do
      parsed when is_integer(parsed) and parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
