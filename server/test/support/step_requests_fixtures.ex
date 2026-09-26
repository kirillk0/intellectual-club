defmodule IntellectualClub.StepRequestsFixtures do
  @moduledoc false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep}
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationShare, LlmProvider}

  def request_message!(actor, opts \\ []) do
    chat = Keyword.get_lazy(opts, :chat, fn -> create!(Chat, :create, %{note: ""}, actor) end)

    create!(
      ChatMessage,
      :add_message,
      %{chat_id: chat.id, role: :assistant, status: opts[:status] || :done},
      actor
    )
  end

  def historical_request_step!(message, sequence, request, actor, attrs \\ %{}) do
    attrs =
      Map.merge(%{chat_message_id: message.id, sequence: sequence, raw_request: request}, attrs)

    create!(ChatMessageStep, :create, attrs, actor)
  end

  def encoded_request_step!(message, sequence, request, actor, opts \\ []) do
    request
    |> StepRequests.create_attributes(Keyword.put(opts, :sequence, sequence))
    |> Map.merge(%{chat_message_id: message.id, sequence: sequence})
    |> then(&create!(ChatMessageStep, :create, &1, actor))
  end

  def stored_request_step!(id, actor) do
    Ash.get!(ChatMessageStep, id,
      actor: actor,
      load: [:raw_request, :request_patch, :raw_response]
    )
  end

  def compact_request(index) do
    %{
      "opaque" => String.duplicate("unchanged", 256),
      "index" => index,
      "nested" => [%{"a/b~c" => [true, nil, "☃"]}]
    }
  end

  def shared_request_message!(owner, recipient) do
    %{group: group} =
      IntellectualClub.AccountsFixtures.user_group_fixture(%{users: [owner, recipient]})

    bot =
      create!(
        Bot,
        :create,
        %{name: "Storage sharing", first_messages: [], history_mode: :chat},
        owner
      )

    provider =
      create!(
        LlmProvider,
        :create,
        %{name: "Storage demo", type: :demo, auth_method: :api_key},
        owner
      )

    configuration =
      create!(
        LlmConfiguration,
        :create,
        %{
          provider_id: provider.id,
          model_name: "demo",
          note: "storage sharing",
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 2048
        },
        owner
      )

    _bot_share = create!(BotShare, :create, %{bot_id: bot.id, user_group_id: group.id}, owner)

    _configuration_share =
      create!(
        LlmConfigurationShare,
        :create,
        %{llm_configuration_id: configuration.id, user_group_id: group.id},
        owner
      )

    chat =
      create!(
        Chat,
        :create,
        %{note: "", bot_id: bot.id, llm_configuration_id: configuration.id},
        owner
      )

    {:ok, _state} = IntellectualClub.Sharing.replace_chat_share_state(chat.id, [group.id], owner)
    request_message!(owner, chat: chat)
  end

  defp create!(resource, action, attrs, actor) do
    resource |> Ash.Changeset.for_create(action, attrs, actor: actor) |> Ash.create!(actor: actor)
  end
end
