defmodule IntellectualClubWeb.Bff.ChatSteerTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  test "steer validates content and requires an active generation", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

    {:ok, assistant_message} =
      Threads.add_message(chat, :assistant, "Answer",
        actor: actor,
        parent_id: user_message.id
      )

    empty_conn =
      post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/steer", %{"content" => ""})

    assert %{"code" => "empty_steering"} = json_response(empty_conn, 422)

    inactive_conn =
      post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/steer", %{
        "content" => "Change direction"
      })

    assert %{"code" => "generation_not_active"} = json_response(inactive_conn, 409)
  end

  test "steer persists outside the canonical trace until generation consumes it", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    configuration = create_configuration!(actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", llm_configuration_id: configuration.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{
          chat_id: chat.id,
          parent_id: user_message.id,
          llm_configuration_id: configuration.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/steer", %{
        "content" => "Change direction"
      })

    queued_message = json_response(conn, 201)["queued_message"]
    assert queued_message["kind"] == "steer"
    assert queued_message["status"] == "pending"
    assert queued_message["target_generation_message_id"] == assistant_message.id

    assert [%{"kind" => "text", "content_text" => "Change direction"}] =
             queued_message["contents"]

    assert {:ok, [persisted]} =
             QueuedMessages.list_pending_steers(assistant_message.id, actor)

    assert persisted.id == queued_message["id"]

    reloaded = Ash.get!(ChatMessage, assistant_message.id, actor: actor, load: [steps: [:items]])
    assert reloaded.steps == []
  end

  defp create_configuration!(actor) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Steering provider",
          type: :openrouter_chat_completion,
          auth_method: :api_key,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "steering-model",
        note: "",
        parameters: %{},
        enabled: true,
        timeout_seconds: 300,
        supports_steering: true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
