defmodule IntellectualClub.Notifications.WebPushSender do
  @moduledoc """
  Thin wrapper around the Web Push transport library.
  """

  alias IntellectualClub.Notifications.WebPushSettings
  alias IntellectualClub.Notifications.WebPushSubscription

  @ttl_seconds 3600

  @spec send(WebPushSubscription.t(), map(), WebPushSettings.t()) ::
          :ok | {:error, :expired | term()}
  def send(%WebPushSubscription{} = subscription, payload, %WebPushSettings{} = settings)
      when is_map(payload) do
    configure_transport(settings)

    subscription_json =
      Jason.encode!(%{
        endpoint: subscription.endpoint,
        keys: %{
          p256dh: subscription.p256dh,
          auth: subscription.auth
        }
      })

    message = Jason.encode!(payload)

    case WebPushElixir.send_notification(subscription_json, message,
           ttl: @ttl_seconds,
           urgency: :normal,
           topic: topic(payload)
         ) do
      {:ok, _response} -> :ok
      {:error, :expired} -> {:error, :expired}
      {:error, {:http_error, status, _body}} when status in [404, 410] -> {:error, :expired}
      {:error, reason} -> {:error, reason}
    end
  end

  defp configure_transport(%WebPushSettings{} = settings) do
    Application.put_env(:web_push_elixir, :vapid_public_key, settings.vapid_public_key)
    Application.put_env(:web_push_elixir, :vapid_private_key, settings.vapid_private_key)
    Application.put_env(:web_push_elixir, :vapid_subject, settings.vapid_subject)
  end

  defp topic(%{chat_id: chat_id}) when is_integer(chat_id), do: "chat-#{chat_id}"
  defp topic(%{"chat_id" => chat_id}) when is_integer(chat_id), do: "chat-#{chat_id}"
  defp topic(_payload), do: nil
end
