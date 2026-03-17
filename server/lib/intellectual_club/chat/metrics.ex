defmodule IntellectualClub.Chat.Metrics do
  @moduledoc """
  Token and history counters for chats.
  """

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock

  require Ash.Query

  def counters(chat_or_id, actor) do
    chat = fetch_chat!(chat_or_id, actor)
    history = Threads.active_branch(chat, actor)

    counters_from_history(chat, history, actor)
  end

  def counters_from_history(chat_or_id, history, actor, opts \\ [])
      when is_list(history) and is_list(opts) do
    chat = fetch_chat!(chat_or_id, actor)

    history_message_count = length(history)

    history_token_count =
      Enum.reduce(history, 0, fn message, total ->
        total + (message.token_count || 0)
      end)

    prompt_token_count =
      case Keyword.get(opts, :prompt_sources) do
        prompt_sources when is_map(prompt_sources) ->
          prompt_tokens_from_sources(prompt_sources)

        _other ->
          prompt_tokens_from_bot(chat.bot_id, actor) +
            prompt_tokens_from_chat(chat.id, actor) +
            prompt_tokens_from_configuration(chat.llm_configuration_id, actor) +
            prompt_tokens_from_user(actor)
      end

    %{
      prompt_token_count: prompt_token_count,
      history_token_count: history_token_count,
      history_message_count: history_message_count,
      total_token_count: prompt_token_count + history_token_count
    }
  end

  defp fetch_chat!(%Chat{} = chat, _actor), do: chat
  defp fetch_chat!(chat_id, actor), do: Ash.get!(Chat, chat_id, actor: actor)

  defp prompt_tokens_from_bot(bot_id, actor) when is_integer(bot_id) do
    BotKnowledgeBlock
    |> Ash.Query.filter(bot_id == ^bot_id and enabled == true)
    |> Ash.Query.load(:knowledge_block)
    |> Ash.read!(actor: actor)
    |> sum_block_tokens()
  end

  defp prompt_tokens_from_bot(_bot_id, _actor), do: 0

  defp prompt_tokens_from_chat(chat_id, actor) when is_integer(chat_id) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat_id and enabled == true)
    |> Ash.Query.load(:knowledge_block)
    |> Ash.read!(actor: actor)
    |> sum_block_tokens()
  end

  defp prompt_tokens_from_chat(_chat_id, _actor), do: 0

  defp prompt_tokens_from_configuration(configuration_id, actor)
       when is_integer(configuration_id) do
    LlmConfigurationKnowledgeBlock
    |> Ash.Query.filter(llm_configuration_id == ^configuration_id and enabled == true)
    |> Ash.Query.load(:knowledge_block)
    |> Ash.read!(actor: actor)
    |> sum_block_tokens()
  end

  defp prompt_tokens_from_configuration(_configuration_id, _actor), do: 0

  defp prompt_tokens_from_user(%{id: owner_id} = actor) when is_integer(owner_id) do
    UserKnowledgeBlock
    |> Ash.Query.filter(owner_id == ^owner_id and enabled == true)
    |> Ash.Query.load(:knowledge_block)
    |> Ash.read!(actor: actor)
    |> sum_block_tokens()
  end

  defp prompt_tokens_from_user(_actor), do: 0

  defp prompt_tokens_from_sources(prompt_sources) when is_map(prompt_sources) do
    [:bot, :chat, :configuration, :user]
    |> Enum.flat_map(fn key -> Map.get(prompt_sources, key, []) |> List.wrap() end)
    |> sum_block_tokens()
  end

  defp sum_block_tokens(bindings) do
    Enum.reduce(bindings, 0, fn binding, total ->
      block_tokens =
        case Map.get(binding, :knowledge_block) do
          %{token_count: token_count} when is_integer(token_count) -> token_count
          _ -> 0
        end

      total + block_tokens
    end)
  end
end
