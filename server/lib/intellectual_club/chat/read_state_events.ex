defmodule IntellectualClub.Chat.ReadStateEvents do
  @moduledoc "User-scoped invalidations for durable chat inbox state."

  @spec topic(pos_integer()) :: String.t()
  def topic(user_id) when is_integer(user_id) and user_id > 0,
    do: "chat_read_state:user:#{user_id}"

  @spec publish(pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def publish(user_id, chat_id)
      when is_integer(user_id) and user_id > 0 and is_integer(chat_id) and chat_id > 0 do
    Phoenix.PubSub.broadcast(
      IntellectualClub.PubSub,
      topic(user_id),
      {:chat_state_changed, chat_id}
    )
  end
end
