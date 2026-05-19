defmodule IntellectualClubWeb.Bff.ChatSharingControllerTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Chat.{Chat, Threads}
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationShare, LlmProvider}

  test "chat sharing BFF is owner-only for shares and read-only for recipients", %{conn: conn} do
    %{user: owner, password: owner_password} = user_fixture()
    %{user: recipient, password: recipient_password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner)
    configuration = create_configuration!(owner)
    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)
    chat = create_chat!(owner, bot, configuration)

    {:ok, _message} =
      Threads.add_message_to_end(chat, :assistant, "hello",
        actor: owner,
        llm_configuration_id: configuration.id
      )

    owner_conn = sign_in_conn(conn, owner.username, owner_password)

    share_payload =
      owner_conn
      |> put(~p"/api/bff/chats/#{chat.id}/shares", %{group_ids: [group.id]})
      |> json_response(200)

    assert share_payload["group_ids"] == [group.id]

    recipient_conn = build_conn() |> sign_in_conn(recipient.username, recipient_password)

    state_payload =
      recipient_conn
      |> get(~p"/api/bff/chats/#{chat.id}/state")
      |> json_response(200)

    assert state_payload["chat"]["can_edit"] == false
    assert state_payload["chat"]["shared_incoming"] == true
    assert length(state_payload["branch"] || []) == 1

    list_payload =
      recipient_conn
      |> get(~p"/api/bff/chats")
      |> json_response(200)

    refute Enum.any?(list_payload["chats"] || [], &(&1["id"] == chat.id))

    recipient_conn
    |> delete(~p"/api/bff/chats/#{chat.id}")
    |> json_response(403)

    recipient_conn
    |> post(~p"/api/bff/chats/#{chat.id}/generate", %{})
    |> json_response(403)

    continue_payload =
      recipient_conn
      |> post(~p"/api/bff/chats/#{chat.id}/continue", %{})
      |> json_response(200)

    new_chat_id = get_in(continue_payload, ["chat", "id"])
    assert is_integer(new_chat_id)
    assert new_chat_id != chat.id
  end

  test "chat state returns not found for unavailable chats", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    conn
    |> sign_in_conn(user.username, password)
    |> get(~p"/api/bff/chats/999999/state")
    |> json_response(404)
  end

  defp create_bot!(actor) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "BFF shared bot #{System.unique_integer([:positive])}",
        first_messages: [],
        variables: %{},
        history_mode: :chat
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_configuration!(actor) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "BFF provider #{System.unique_integer([:positive])}",
          type: :demo,
          auth_method: :api_key
        },
        actor: actor
      )
      |> Ash.create!()

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "demo-model",
        note: "shared",
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        context_length: 2048
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_chat!(actor, bot, configuration) do
    Chat
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: "BFF shared chat",
        note: "",
        bot_id: bot.id,
        llm_configuration_id: configuration.id,
        variables: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(:create, %{bot_id: bot.id, user_group_id: group.id}, actor: actor)
    |> Ash.create!()
  end

  defp share_configuration!(actor, configuration, group) do
    LlmConfigurationShare
    |> Ash.Changeset.for_create(
      :create,
      %{llm_configuration_id: configuration.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!()
  end
end
