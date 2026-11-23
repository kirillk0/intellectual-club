defmodule IntellectualClub.Chat.Metrics do
  @moduledoc """
  Token and history counters for chats.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.TokenCounter

  def counters(chat_or_id, actor) do
    chat = fetch_chat!(chat_or_id, actor)
    history = Threads.active_branch(chat, actor)
    snapshot = Context.prompt_snapshot!(chat, actor: actor)

    counters_from_history(history, snapshot.system_prompt)
  end

  def counters_from_history(history, system_prompt) do
    %{
      prompt_token_count: TokenCounter.estimate(system_prompt),
      history_token_count: Enum.sum_by(history, &(&1.token_count || 0)),
      history_message_count: length(history)
    }
  end

  defp fetch_chat!(%Chat{} = chat, _actor), do: chat
  defp fetch_chat!(chat_id, actor), do: Ash.get!(Chat, chat_id, actor: actor)
end
