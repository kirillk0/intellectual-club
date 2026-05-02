defmodule IntellectualClubWeb.Bff.ChatCreateTest do
  @moduledoc """
  Chat creation endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationTag}
  alias IntellectualClub.Llm.LlmProvider

  test "POST /api/bff/chats defaults configuration from latest chat for selected bot", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_bot!(actor, "Assistant")
    provider = create_provider!(actor, "Provider A")
    config_old = create_configuration!(actor, provider, "model-old")
    config_new = create_configuration!(actor, provider, "model-new")

    _old_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Old chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: config_old.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _new_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "New chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: config_new.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn = post(conn, ~p"/api/bff/chats", %{"bot_id" => bot.id})
    payload = json_response(conn, 200)

    assert payload["chat"]["llm_configuration_id"] == config_new.id
  end

  test "POST /api/bff/chats does not override explicit null configuration", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_bot!(actor, "Assistant")
    provider = create_provider!(actor, "Provider A")
    config = create_configuration!(actor, provider, "model-1")

    _chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Existing chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      post(conn, ~p"/api/bff/chats", %{
        "bot_id" => bot.id,
        "llm_configuration_id" => nil
      })

    payload = json_response(conn, 200)

    assert payload["chat"]["llm_configuration_id"] == nil
  end

  test "POST /api/bff/chats uses latest configuration from the same bot only", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot_a = create_bot!(actor, "Bot A")
    bot_b = create_bot!(actor, "Bot B")
    provider = create_provider!(actor, "Provider A")
    config_a = create_configuration!(actor, provider, "model-a")
    config_b = create_configuration!(actor, provider, "model-b")

    _chat_for_bot_a =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Bot A chat",
          note: "",
          bot_id: bot_a.id,
          llm_configuration_id: config_a.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _chat_for_bot_b =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Bot B chat",
          note: "",
          bot_id: bot_b.id,
          llm_configuration_id: config_b.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn = post(conn, ~p"/api/bff/chats", %{"bot_id" => bot_a.id})
    payload = json_response(conn, 200)

    assert payload["chat"]["llm_configuration_id"] == config_a.id
  end

  test "POST /api/bff/chats defaults configuration from latest no bot chat", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "Provider A")
    config_old = create_configuration!(actor, provider, "model-old")
    config_new = create_configuration!(actor, provider, "model-new")

    _old_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Old no bot chat",
          note: "",
          llm_configuration_id: config_old.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _new_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "New no bot chat",
          note: "",
          llm_configuration_id: config_new.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn = post(conn, ~p"/api/bff/chats", %{})
    payload = json_response(conn, 200)

    assert payload["chat"]["bot_id"] == nil
    assert payload["chat"]["llm_configuration_id"] == config_new.id
  end

  test "POST /api/bff/chats defaults to the first available configuration when chats do not exist yet",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "Provider A")
    config_b = create_configuration!(actor, provider, "model-b")
    config_a = create_configuration!(actor, provider, "model-a")

    conn = post(conn, ~p"/api/bff/chats", %{})
    payload = json_response(conn, 200)

    assert payload["chat"]["bot_id"] == nil
    assert payload["chat"]["llm_configuration_id"] == config_a.id
    refute payload["chat"]["llm_configuration_id"] == config_b.id
  end

  test "POST /api/bff/chats uses bot default configuration when selected bot has no chats",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "Provider A")
    fallback_config = create_configuration!(actor, provider, "model-a")
    default_config = create_configuration!(actor, provider, "model-b")
    bot = create_bot!(actor, "Assistant", %{default_llm_configuration_id: default_config.id})

    payload =
      conn
      |> post(~p"/api/bff/chats", %{"bot_id" => bot.id})
      |> json_response(200)

    assert payload["chat"]["llm_configuration_id"] == default_config.id
    refute payload["chat"]["llm_configuration_id"] == fallback_config.id
  end

  test "POST /api/bff/chats prefers latest chat configuration over bot default",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "Provider A")
    default_config = create_configuration!(actor, provider, "model-default")
    latest_config = create_configuration!(actor, provider, "model-latest")
    bot = create_bot!(actor, "Assistant", %{default_llm_configuration_id: default_config.id})

    _latest_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Latest chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: latest_config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    payload =
      conn
      |> post(~p"/api/bff/chats", %{"bot_id" => bot.id})
      |> json_response(200)

    assert payload["chat"]["llm_configuration_id"] == latest_config.id
  end

  test "POST /api/bff/chats defaults to the latest compatible configuration for the selected bot",
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

    _compatible_chat =
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

    _incompatible_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Incompatible chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: incompatible_config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    payload =
      conn
      |> post(~p"/api/bff/chats", %{"bot_id" => bot.id})
      |> json_response(200)

    assert payload["chat"]["llm_configuration_id"] == compatible_config.id
  end

  test "POST /api/bff/chats matches shared bot configuration tags by name", %{conn: conn} do
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

    _incompatible_config =
      create_configuration!(recipient, provider, "model-incompatible", other_tag.id)

    payload =
      conn
      |> post(~p"/api/bff/chats", %{"bot_id" => bot.id})
      |> json_response(200)

    assert payload["chat"]["bot_id"] == bot.id
    assert payload["chat"]["llm_configuration_id"] == compatible_config.id
  end

  test "POST /api/bff/chats falls back to the first compatible configuration when latest bot chat is no longer compatible",
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

    _incompatible_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Incompatible chat",
          note: "",
          bot_id: bot.id,
          llm_configuration_id: incompatible_config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    payload =
      conn
      |> post(~p"/api/bff/chats", %{"bot_id" => bot.id})
      |> json_response(200)

    assert payload["chat"]["llm_configuration_id"] == compatible_config.id
  end

  test "POST /api/bff/chats uses bot default even when disabled and tag-incompatible",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    compatible_tag = create_configuration_tag!(actor, "Compatible")
    other_tag = create_configuration_tag!(actor, "Other")

    provider = create_provider!(actor, "Provider A")

    _compatible_config =
      create_configuration!(actor, provider, "model-compatible", compatible_tag.id)

    default_config =
      create_configuration!(actor, provider, "model-disabled-incompatible", other_tag.id)

    bot =
      create_bot!(actor, "Assistant", %{
        default_llm_configuration_id: default_config.id,
        compatible_configuration_tag_bindings: [%{llm_configuration_tag_id: compatible_tag.id}]
      })

    default_config
    |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: actor)
    |> Ash.update!(actor: actor)

    payload =
      conn
      |> post(~p"/api/bff/chats", %{"bot_id" => bot.id})
      |> json_response(200)

    assert payload["chat"]["llm_configuration_id"] == default_config.id
  end

  test "POST /api/bff/chats falls back to the first available configuration when latest no bot configuration is disabled",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "Provider A")
    fallback_config = create_configuration!(actor, provider, "model-a")
    disabled_config = create_configuration!(actor, provider, "model-b")

    _chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Latest no bot chat",
          note: "",
          llm_configuration_id: disabled_config.id,
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    disabled_config
    |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: actor)
    |> Ash.update!(actor: actor)

    payload =
      conn
      |> post(~p"/api/bff/chats", %{})
      |> json_response(200)

    assert payload["chat"]["llm_configuration_id"] == fallback_config.id
  end

  defp create_bot!(actor, name, attrs \\ %{}) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          name: name,
          first_messages: [],
          variables: %{},
          max_tool_rounds: 20,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!(actor: actor)
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

  defp create_configuration!(actor, provider, model_name, tag_id \\ nil) do
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
        tag_bindings: if(is_integer(tag_id), do: [%{llm_configuration_tag_id: tag_id}], else: nil)
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
