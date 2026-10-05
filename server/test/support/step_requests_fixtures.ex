defmodule IntellectualClub.StepRequestsFixtures do
  @moduledoc """
  Fixtures for step request storage: assistant messages whose steps carry a
  historical `raw_request` or an encoded (full, patch or checkpoint) request.
  """

  alias IntellectualClub.{BotsFixtures, ChatFixtures, LlmFixtures}
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep}
  alias IntellectualClub.Generation.StepRequests

  @doc "Creates an assistant message (default `status: :done`) in `opts[:chat]` or a new chat."
  def request_message!(actor, opts \\ []) do
    chat = Keyword.get_lazy(opts, :chat, fn -> create!(Chat, :create, %{note: ""}, actor) end)

    create!(
      ChatMessage,
      :add_message,
      %{chat_id: chat.id, role: :assistant, status: opts[:status] || :done},
      actor
    )
  end

  @doc "Creates a step with a legacy full `raw_request` (no encoding metadata)."
  def historical_request_step!(message, sequence, request, actor, attrs \\ %{}) do
    attrs =
      Map.merge(%{chat_message_id: message.id, sequence: sequence, raw_request: request}, attrs)

    create!(ChatMessageStep, :create, attrs, actor)
  end

  @doc "Creates a step whose request is encoded by `StepRequests.create_attributes/2`."
  def encoded_request_step!(message, sequence, request, actor, opts \\ []) do
    request
    |> StepRequests.create_attributes(Keyword.put(opts, :sequence, sequence))
    |> Map.merge(%{chat_message_id: message.id, sequence: sequence})
    |> then(&create!(ChatMessageStep, :create, &1, actor))
  end

  @doc "Reads a step with its physical request columns and response."
  def stored_request_step!(id, actor) do
    Ash.get!(ChatMessageStep, id,
      actor: actor,
      load: [:raw_request, :request_patch, :raw_response]
    )
  end

  @doc "A request that compresses well into patches: large unchanged opaque data plus an index."
  def compact_request(index) do
    %{
      "opaque" => String.duplicate("unchanged", 256),
      "index" => index,
      "nested" => [%{"a/b~c" => [true, nil, "☃"]}]
    }
  end

  @doc """
  Creates an assistant message in a chat of `owner` (with a bot and an LLM
  configuration shared to a group of `owner` and `recipient`) that is shared
  with that group.
  """
  def shared_request_message!(owner, recipient) do
    %{group: group} =
      IntellectualClub.AccountsFixtures.user_group_fixture(%{users: [owner, recipient]})

    bot = BotsFixtures.create_bot!(owner, name: "Storage sharing")

    configuration =
      LlmFixtures.create_configuration!(owner, model_name: "demo", note: "storage sharing")

    BotsFixtures.share_bot!(owner, bot, group)
    LlmFixtures.share_configuration!(owner, configuration, group)

    chat =
      ChatFixtures.create_chat!(owner, bot_id: bot.id, llm_configuration_id: configuration.id)

    {:ok, _state} = IntellectualClub.Sharing.replace_chat_share_state(chat.id, [group.id], owner)
    request_message!(owner, chat: chat)
  end

  defp create!(resource, action, attrs, actor) do
    resource |> Ash.Changeset.for_create(action, attrs, actor: actor) |> Ash.create!(actor: actor)
  end
end
