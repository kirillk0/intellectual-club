defmodule IntellectualClubWeb.Bff.SharingControllerTest do
  @moduledoc """
  BFF sharing endpoint tests for bot and configuration sharing.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationShare, LlmProvider}
  alias IntellectualClub.Tools.{BotToolBinding, ToolInstance}

  require Ash.Query

  test "GET /api/bff/me/groups returns only actor memberships even for admins", %{conn: conn} do
    %{user: admin, password: password} = user_fixture(%{is_admin: true})
    %{group: member_group} = user_group_fixture(%{name: "Member group", users: [admin]})
    %{group: other_group} = user_group_fixture(%{name: "Other group"})

    payload =
      conn
      |> sign_in_conn(admin.username, password)
      |> get("/api/bff/me/groups")
      |> json_response(200)

    assert Enum.map(payload["groups"] || [], & &1["id"]) == [member_group.id]
    refute Enum.any?(payload["groups"] || [], &(&1["id"] == other_group.id))
  end

  test "PUT /api/bff/bots/:id/shares replaces groups and tool modes", %{conn: conn} do
    %{user: owner, password: password} = user_fixture()
    %{user: member_a} = user_fixture()
    %{user: member_b} = user_fixture()
    %{group: group_a} = user_group_fixture(%{users: [owner, member_a]})
    %{group: group_b} = user_group_fixture(%{users: [owner, member_b]})

    bot = create_bot!(owner, "Shared bot")
    tool_a = create_tool!(owner, "Tool A")
    tool_b = create_tool!(owner, "Tool B")

    binding_a = create_bot_tool_binding!(owner, bot, tool_a, "team_web", :shared, 10)
    binding_b = create_bot_tool_binding!(owner, bot, tool_b, "docs", :shared, 20)

    payload =
      conn
      |> sign_in_conn(owner.username, password)
      |> put("/api/bff/bots/#{bot.id}/shares", %{
        "group_ids" => [group_b.id, group_a.id],
        "tool_modes" => %{
          Integer.to_string(binding_a.id) => "per_user",
          Integer.to_string(binding_b.id) => "shared"
        }
      })
      |> json_response(200)

    assert payload["group_ids"] == Enum.sort([group_a.id, group_b.id])

    assert payload["tool_modes"] == %{
             Integer.to_string(binding_a.id) => "per_user",
             Integer.to_string(binding_b.id) => "shared"
           }

    share_group_ids =
      BotShare
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.read!(actor: owner)
      |> Enum.map(& &1.user_group_id)
      |> Enum.sort()

    assert share_group_ids == Enum.sort([group_a.id, group_b.id])
    assert Ash.get!(BotToolBinding, binding_a.id, actor: owner).sharing_mode == :per_user
    assert Ash.get!(BotToolBinding, binding_b.id, actor: owner).sharing_mode == :shared
  end

  test "PUT /api/bff/bots/:id/shares rejects groups outside actor memberships", %{conn: conn} do
    %{user: owner, password: password} = user_fixture()
    %{group: foreign_group} = user_group_fixture()
    bot = create_bot!(owner, "Restricted bot")

    payload =
      conn
      |> sign_in_conn(owner.username, password)
      |> put("/api/bff/bots/#{bot.id}/shares", %{"group_ids" => [foreign_group.id]})
      |> json_response(422)

    assert payload["error"] == "You can only share to your own groups."
  end

  test "PUT /api/bff/bots/:id/shares rolls back group changes when tool_modes are invalid", %{
    conn: conn
  } do
    %{user: owner, password: password} = user_fixture()
    %{user: member} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, member]})
    bot = create_bot!(owner, "Atomic bot")
    tool = create_tool!(owner, "Atomic tool")
    binding = create_bot_tool_binding!(owner, bot, tool, "team_web", :shared, 10)

    payload =
      conn
      |> sign_in_conn(owner.username, password)
      |> put("/api/bff/bots/#{bot.id}/shares", %{
        "group_ids" => [group.id],
        "tool_modes" => %{"999999" => "shared"}
      })
      |> json_response(422)

    assert payload["error"] == "tool_modes contains unknown bot tool bindings."

    shares =
      BotShare
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.read!(actor: owner)

    assert shares == []
    assert Ash.get!(BotToolBinding, binding.id, actor: owner).sharing_mode == :shared
  end

  test "configuration share endpoints replace groups and stay owner-only", %{conn: conn} do
    %{user: owner, password: owner_password} = user_fixture()
    %{user: recipient, password: recipient_password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    provider = create_provider!(owner, "Provider")
    configuration = create_configuration!(owner, provider, "shared-model")

    owner_conn = sign_in_conn(conn, owner.username, owner_password)

    update_payload =
      owner_conn
      |> put("/api/bff/llm-configurations/#{configuration.id}/shares", %{
        "group_ids" => [group.id]
      })
      |> json_response(200)

    assert update_payload["group_ids"] == [group.id]

    show_payload =
      owner_conn
      |> get("/api/bff/llm-configurations/#{configuration.id}/shares")
      |> json_response(200)

    assert show_payload["group_ids"] == [group.id]

    recipient_conn = sign_in_conn(build_conn(), recipient.username, recipient_password)

    forbidden_payload =
      recipient_conn
      |> get("/api/bff/llm-configurations/#{configuration.id}/shares")
      |> json_response(403)

    assert forbidden_payload["error"] == "Forbidden"

    share_group_ids =
      LlmConfigurationShare
      |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
      |> Ash.read!(actor: owner)
      |> Enum.map(& &1.user_group_id)

    assert share_group_ids == [group.id]
  end

  defp create_bot!(actor, name) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        variables: %{},
        max_tool_rounds: 20,
        context_soft_limit_percent: 80,
        history_mode: :chat
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_provider!(actor, name) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        type: :demo,
        auth_method: :api_key,
        base_url: nil,
        api_key: nil
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_configuration!(actor, provider, model_name) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: model_name,
        note: "cfg",
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        context_length: 2048,
        supports_cache_control: false,
        supports_image_input: false
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_tool!(actor, name) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "mcp_http",
        name: name,
        config: %{"server_url" => "https://example.com/mcp"},
        secrets: %{"bearer_token" => "token"},
        max_output_tokens: 2000
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_bot_tool_binding!(actor, bot, tool, alias_value, sharing_mode, sequence) do
    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: tool.id,
        alias: alias_value,
        sharing_mode: sharing_mode,
        enabled: true,
        sequence: sequence
      },
      actor: actor
    )
    |> Ash.create!()
  end
end
