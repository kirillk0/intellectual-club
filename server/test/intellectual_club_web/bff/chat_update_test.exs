defmodule IntellectualClubWeb.Bff.ChatUpdateTest do
  @moduledoc """
  Chat update endpoint tests for compatibility-aware bot/config switching.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationTag, LlmProvider}

  require Ash.Query

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
          note: "",
          bot_id: bot.id,
          llm_configuration_id: compatible_config.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "",
          llm_configuration_id: incompatible_config.id
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

  test "PATCH /api/bff/chats/:id matches shared bot configuration tags by name", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})
    conn = sign_in_conn(conn, recipient.username, password)

    owner_tag = create_configuration_tag!(owner, "Compatible")
    recipient_tag = create_configuration_tag!(recipient, "compatible")
    other_tag = create_configuration_tag!(recipient, "Other")

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Shared compatible bot",
          compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: owner_tag.id}]
        },
        actor: owner
      )
      |> Ash.create!(actor: owner)

    share_bot!(owner, bot, group)

    provider = create_provider!(recipient, "Recipient provider")

    compatible_config =
      create_configuration!(recipient, provider, "model-compatible", recipient_tag.id)

    incompatible_config =
      create_configuration!(recipient, provider, "model-incompatible", other_tag.id)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "",
          llm_configuration_id: incompatible_config.id
        },
        actor: recipient
      )
      |> Ash.create!(actor: recipient)

    payload =
      conn
      |> patch(~p"/api/bff/chats/#{chat.id}", %{"bot_id" => bot.id})
      |> json_response(200)

    assert payload["chat"]["bot_id"] == bot.id
    assert payload["chat"]["llm_configuration_id"] == compatible_config.id
  end

  test "PATCH /api/bff/chats/:id manages chat tool bindings", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tool_a =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "Tool A",
          alias: "web",
          config: %{"server_url" => "https://example.com/a"},
          secrets: %{"bearer_token" => "a"}
        },
        actor: actor
      )
      |> Ash.create!()

    tool_b =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "Tool B",
          alias: "reader",
          config: %{"server_url" => "https://example.com/b"},
          secrets: %{"bearer_token" => "b"}
        },
        actor: actor
      )
      |> Ash.create!()

    _payload =
      conn
      |> patch(~p"/api/bff/chats/#{chat.id}", %{
        "tool_bindings" => [
          %{"tool_instance_id" => tool_a.id, "enabled" => true},
          %{"tool_instance_id" => tool_b.id, "enabled" => false}
        ]
      })
      |> json_response(200)

    bindings =
      ChatToolBinding
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.Query.load([:alias])
      |> Ash.read!(actor: actor)

    assert Enum.map(bindings, &{&1.alias, &1.tool_instance_id, &1.enabled, &1.sequence}) == [
             {"web", tool_a.id, true, 0},
             {"reader", tool_b.id, false, 1}
           ]

    [first_binding | _] = bindings

    _payload =
      conn
      |> patch(~p"/api/bff/chats/#{chat.id}", %{
        "tool_bindings" => [
          %{
            "id" => first_binding.id,
            "tool_instance_id" => tool_b.id,
            "enabled" => false
          }
        ]
      })
      |> json_response(200)

    bindings =
      ChatToolBinding
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.Query.load([:alias])
      |> Ash.read!(actor: actor)

    assert Enum.map(bindings, &{&1.alias, &1.tool_instance_id, &1.enabled, &1.sequence}) == [
             {"reader", tool_b.id, false, 0}
           ]
  end

  test "GET /api/bff/chats/:id/state returns only effective active tool bindings", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot =
      Bot
      |> Ash.Changeset.for_create(:create, %{name: "Tool state bot"}, actor: actor)
      |> Ash.create!(actor: actor)

    bot_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "Bot Tool",
          alias: "web",
          config: %{"server_url" => "https://example.com/bot"},
          secrets: %{"bearer_token" => "bot"}
        },
        actor: actor
      )
      |> Ash.create!()

    chat_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Chat Tool",
          alias: "web",
          config: %{},
          secrets: %{"token" => "chat"}
        },
        actor: actor
      )
      |> Ash.create!()

    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: bot_tool.id,
        sharing_mode: :shared,
        enabled: true,
        sequence: 10
      },
      actor: actor
    )
    |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: chat_tool.id, enabled: true, sequence: 0},
      actor: actor
    )
    |> Ash.create!()

    payload =
      conn
      |> get(~p"/api/bff/chats/#{chat.id}/settings-state")
      |> json_response(200)

    assert [%{"alias" => "web", "source" => "chat", "tool_instance" => tool_payload}] =
             payload["active_tool_bindings"]

    assert tool_payload["id"] == chat_tool.id
    assert tool_payload["name"] == "Chat Tool"
    assert tool_payload["type"] == "native-brave-search"
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

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
