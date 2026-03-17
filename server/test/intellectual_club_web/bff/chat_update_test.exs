defmodule IntellectualClubWeb.Bff.ChatUpdateTest do
  @moduledoc """
  Chat update endpoint tests for compatibility-aware bot/config switching.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationTag, LlmProvider}

  test "PATCH /api/bff/chats/:id switches to the latest compatible configuration when bot changes",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    compatible_tag = create_configuration_tag!(actor, "Compatible")
    other_tag = create_configuration_tag!(actor, "Other")

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Compatible bot",
          compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: compatible_tag.id}]
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    provider = create_provider!(actor, "Provider A")

    compatible_config =
      create_configuration!(actor, provider, "model-compatible", compatible_tag.id)

    incompatible_config =
      create_configuration!(actor, provider, "model-incompatible", other_tag.id)

    _existing_compatible_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Compatible chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: compatible_config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Bot switch chat",
          note: "",
          llm_configuration_id: incompatible_config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    payload =
      conn
      |> patch(~p"/api/bff/chats/#{chat.id}", %{"bot_id" => bot.id})
      |> json_response(200)

    assert payload["chat"]["bot_id"] == bot.id
    assert payload["chat"]["llm_configuration_id"] == compatible_config.id
  end

  defp create_provider!(actor, name) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        type: :openrouter_chat_completion,
        auth_method: :api_key,
        base_url: "https://openrouter.ai/api/v1",
        api_key: "test-key"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration!(actor, provider, model_name, tag_id) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: model_name,
        note: "cfg",
        parameters: %{},
        enabled: true,
        timeout_seconds: 300,
        tag_bindings: [%{llm_configuration_tag_id: tag_id}]
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration_tag!(actor, name) do
    LlmConfigurationTag
    |> Ash.Changeset.for_create(:create, %{name: name}, actor: actor)
    |> Ash.create!(actor: actor)
  end
end
