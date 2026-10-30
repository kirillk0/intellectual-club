defmodule IntellectualClubWeb.Bff.ChatEventsController do
  @moduledoc "Authenticated, short-lived SSE invalidations for a user's chat inbox."
  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.ReadStateEvents
  alias IntellectualClubWeb.Bff.Helpers

  def index(conn, _params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      topic = ReadStateEvents.topic(actor.id)
      :ok = Phoenix.PubSub.subscribe(IntellectualClub.PubSub, topic)

      try do
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(:ok)

        ttl = positive_config(:chat_events_stream_ttl_ms, 60_000)
        heartbeat = positive_config(:chat_events_heartbeat_ms, 15_000)
        deadline = System.monotonic_time(:millisecond) + ttl

        case chunk(conn, "retry: 1000\n: connected\n\n") do
          {:ok, conn} -> stream(conn, deadline, heartbeat)
          {:error, _reason} -> conn
        end
      after
        Phoenix.PubSub.unsubscribe(IntellectualClub.PubSub, topic)
      end
    else
      {:error, conn} -> conn
    end
  end

  defp stream(conn, deadline, heartbeat) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      conn
    else
      receive do
        {:chat_state_changed, chat_id} when is_integer(chat_id) and chat_id > 0 ->
          data = Jason.encode!(%{chat_id: chat_id})
          continue(conn, "event: chat_state_changed\ndata: #{data}\n\n", deadline, heartbeat)
      after
        min(heartbeat, remaining) ->
          continue(conn, ": heartbeat\n\n", deadline, heartbeat)
      end
    end
  end

  defp continue(conn, data, deadline, heartbeat) do
    case chunk(conn, data) do
      {:ok, conn} -> stream(conn, deadline, heartbeat)
      {:error, _reason} -> conn
    end
  end

  defp positive_config(key, default) do
    case Application.get_env(:intellectual_club, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
