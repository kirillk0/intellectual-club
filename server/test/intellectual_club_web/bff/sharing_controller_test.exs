defmodule IntellectualClubWeb.Bff.SharingControllerTest do
  @moduledoc """
  Sharing BFF endpoints for chats, bots, configurations, knowledge blocks and tools.
  """

  use IntellectualClubWeb.ConnCase, async: true

  alias IntellectualClub.Bots.BotShare
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Knowledge.KnowledgeBlockShare
  alias IntellectualClub.Llm.LlmConfigurationShare
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ToolInstanceShare

  require Ash.Query

  describe "chat shares" do
    test "chat sharing BFF is owner-only for shares and read-only for recipients", %{conn: conn} do
      %{user: owner, password: owner_password} = user_fixture()
      %{user: recipient, password: recipient_password} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})

      bot = create_bot!(owner, max_tool_rounds: 300)
      configuration = create_configuration!(owner, note: "shared")
      share_bot!(owner, bot, group)
      share_configuration!(owner, configuration, group)
      chat = create_chat!(owner, bot_id: bot.id, llm_configuration_id: configuration.id)

      {:ok, _message} =
        Threads.add_message_to_end(chat, :assistant, "hello",
          actor: owner,
          llm_configuration_id: configuration.id
        )

      owner_conn = sign_in_conn(conn, owner.username, owner_password)

      share_payload =
        owner_conn
        |> put(~p"/api/bff/chat-shares/#{chat.id}", %{group_ids: [group.id]})
        |> json_response(200)

      assert share_payload["group_ids"] == [group.id]

      recipient_conn = build_conn() |> sign_in_conn(recipient.username, recipient_password)

      state_payload =
        recipient_conn
        |> get(~p"/api/bff/chat-state/#{chat.id}")
        |> json_response(200)

      assert state_payload["chat"]["can_edit"] == false
      assert state_payload["chat"]["shared_incoming"] == true
      assert length(state_payload["branch"] || []) == 1

      list_payload =
        recipient_conn
        |> get(~p"/api/bff/chat-list")
        |> json_response(200)

      refute Enum.any?(list_payload["chats"] || [], &(&1["id"] == chat.id))

      delete_conn =
        recipient_conn
        |> json_api_delete("/api/ash/chats/#{chat.id}")

      assert delete_conn.status in [403, 404]

      recipient_conn
      |> post(~p"/api/bff/chat-generation/#{chat.id}/generate", %{})
      |> json_response(403)

      continue_payload =
        recipient_conn
        |> json_api_post("/api/ash/chats/#{chat.id}/continue", json_api_data("chats", %{}))
        |> json_response(201)

      new_chat_id =
        continue_payload
        |> get_in(["data", "id"])
        |> String.to_integer()

      assert is_integer(new_chat_id)
      assert new_chat_id != chat.id
    end

    test "chat state returns not found for unavailable chats", %{conn: conn} do
      %{user: user, password: password} = user_fixture()

      conn
      |> sign_in_conn(user.username, password)
      |> get(~p"/api/bff/chat-state/999999")
      |> json_response(404)
    end
  end

  describe "resource shares" do
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

      bot = create_bot!(owner, name: "Shared bot")
      tool_a = create_tool_instance!(owner, name: "Tool A", max_output_tokens: 2000)
      tool_b = create_tool_instance!(owner, name: "Tool B", max_output_tokens: 2000)

      binding_a =
        create_bot_tool_binding!(owner, bot, tool_a,
          alias: "team_web",
          sharing_mode: :shared,
          sequence: 10
        )

      binding_b =
        create_bot_tool_binding!(owner, bot, tool_b,
          alias: "docs",
          sharing_mode: :shared,
          sequence: 20
        )

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
      bot = create_bot!(owner, name: "Restricted bot")

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
      bot = create_bot!(owner, name: "Atomic bot")
      tool = create_tool_instance!(owner, name: "Atomic tool", max_output_tokens: 2000)

      binding =
        create_bot_tool_binding!(owner, bot, tool,
          alias: "team_web",
          sharing_mode: :shared,
          sequence: 10
        )

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

      provider = create_provider!(owner, name: "Provider")
      configuration = create_configuration!(owner, provider: provider, model_name: "shared-model")

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

    test "knowledge block and tool share endpoints replace direct group access", %{conn: conn} do
      %{user: owner, password: owner_password} = user_fixture()
      %{user: recipient, password: recipient_password} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})
      block = create_knowledge_block!(owner, content: "Direct content", name: "Direct block")
      tool = create_tool_instance!(owner, name: "Direct tool", max_output_tokens: 2000)
      owner_conn = sign_in_conn(conn, owner.username, owner_password)

      block_payload =
        owner_conn
        |> put("/api/bff/knowledge-blocks/#{block.id}/shares", %{
          "group_ids" => [Integer.to_string(group.id)]
        })
        |> json_response(200)

      tool_payload =
        owner_conn
        |> put("/api/bff/tool-instances/#{tool.id}/shares", %{"group_ids" => [group.id]})
        |> json_response(200)

      assert block_payload["group_ids"] == [group.id]
      assert tool_payload["group_ids"] == [group.id]

      assert [
               %KnowledgeBlockShare{
                 knowledge_block_id: block_id,
                 user_group_id: group_id
               }
             ] =
               KnowledgeBlockShare
               |> Ash.Query.filter(knowledge_block_id == ^block.id)
               |> Ash.read!(actor: owner)

      assert block_id == block.id
      assert group_id == group.id

      assert [
               %ToolInstanceShare{
                 tool_instance_id: tool_id,
                 user_group_id: tool_group_id
               }
             ] =
               ToolInstanceShare
               |> Ash.Query.filter(tool_instance_id == ^tool.id)
               |> Ash.read!(actor: owner)

      assert tool_id == tool.id
      assert tool_group_id == group.id

      recipient_conn = sign_in_conn(build_conn(), recipient.username, recipient_password)

      assert %{"error" => "Forbidden"} =
               recipient_conn
               |> get("/api/bff/knowledge-blocks/#{block.id}/shares")
               |> json_response(403)

      assert %{"error" => "Forbidden"} =
               recipient_conn
               |> get("/api/bff/tool-instances/#{tool.id}/shares")
               |> json_response(403)

      assert %{"group_ids" => []} =
               owner_conn
               |> put("/api/bff/knowledge-blocks/#{block.id}/shares", %{"group_ids" => []})
               |> json_response(200)

      assert %{"group_ids" => []} =
               owner_conn
               |> put("/api/bff/tool-instances/#{tool.id}/shares", %{"group_ids" => []})
               |> json_response(200)
    end
  end
end
