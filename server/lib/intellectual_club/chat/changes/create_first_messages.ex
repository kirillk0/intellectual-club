defmodule IntellectualClub.Chat.Changes.CreateFirstMessages do
  @moduledoc """
  Creates assistant root messages from `bot.first_messages` when a chat is created.
  """

  use Ash.Resource.Change

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Threads

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, chat ->
      actor = changeset.context[:private][:actor]

      if is_integer(chat.bot_id) do
        bot = Ash.get!(Bot, chat.bot_id, actor: actor)

        bot.first_messages
        |> List.wrap()
        |> Enum.map(&to_string(&1 || ""))
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.reduce_while({:ok, chat}, fn content, {:ok, _chat} ->
          {:ok, _message} = create_first_message(chat.id, content, actor)
          {:cont, {:ok, chat}}
        end)
      else
        {:ok, chat}
      end
    end)
  end

  defp create_first_message(chat_id, content, actor) do
    Threads.add_message(chat_id, :assistant, content,
      actor: actor,
      parent_id: nil,
      status: :done
    )
  end
end
