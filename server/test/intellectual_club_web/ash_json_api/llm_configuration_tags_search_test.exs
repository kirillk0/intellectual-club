defmodule IntellectualClubWeb.AshJsonApi.LlmConfigurationTagsSearchTest do
  @moduledoc """
  Regression tests for filtering editable LLM configuration tags in JSON:API search.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotCompatibleConfigurationTag, BotShare}
  alias IntellectualClub.Llm.LlmConfigurationTag

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  defp ids_from_response(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
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
    |> Ash.create!(actor: actor)
  end

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        user_group_id: group.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  test "GET /api/ash/llm-configuration-tags supports editable_only for foreign tags visible via shared bots",
       %{
    conn: conn
  } do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    owner_tag =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Shared Tag"}, actor: owner)
      |> Ash.create!(actor: owner)

    recipient_tag =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Own Tag"}, actor: recipient)
      |> Ash.create!(actor: recipient)

    bot = create_bot!(owner, "Shared bot")

    BotCompatibleConfigurationTag
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot.id, llm_configuration_tag_id: owner_tag.id},
      actor: owner
    )
    |> Ash.create!(actor: owner)

    share_bot!(owner, bot, group)

    foreign_show_response =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_get("/api/ash/llm-configuration-tags/#{owner_tag.id}")
      |> json_response(200)

    assert get_in(foreign_show_response, ["data", "id"]) == Integer.to_string(owner_tag.id)

    editable_response =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_get("/api/ash/llm-configuration-tags?sort=name&editable_only=true")
      |> json_response(200)

    assert ids_from_response(editable_response) == [recipient_tag.id]
  end
end
