defmodule IntellectualClub.BotsFixtures do
  @moduledoc """
  Fixtures for bots and bot sharing.

  Tool bindings live in `IntellectualClub.ToolsFixtures`, knowledge block
  bindings in `IntellectualClub.KnowledgeFixtures`.
  """

  import IntellectualClub.Fixtures

  alias IntellectualClub.Bots.{Bot, BotShare}

  @doc """
  Creates a bot. Defaults: a unique `name`, `first_messages: []`,
  `max_tool_rounds: 20`, `context_soft_limit_percent: 80`, `history_mode: :chat`.

  Note that these differ from the resource defaults (`max_tool_rounds: 300`,
  `history_mode: :agent`); pass them explicitly when the test depends on them.
  Relationship arguments such as `:tool_bindings`, `:knowledge_block_bindings`
  and `:compatible_configuration_tag_bindings` are passed through.
  """
  def create_bot!(actor, attrs \\ %{}) do
    defaults = %{
      name: unique_name("Bot"),
      first_messages: [],
      max_tool_rounds: 20,
      context_soft_limit_percent: 80,
      history_mode: :chat
    }

    create!(Bot, merge_attrs(defaults, attrs), actor)
  end

  @doc "Shares `bot` with `group`."
  def share_bot!(actor, bot, group) do
    create!(BotShare, %{bot_id: bot.id, user_group_id: group.id}, actor)
  end

  @doc """
  Creates a bot named `name` with a bound `native-artifact-reader` tool
  instance (alias `"artifacts"`); `attrs` override the bot attributes.
  """
  def create_artifact_bot!(actor, name, attrs \\ []) do
    bot = create_bot!(actor, Keyword.put(attrs, :name, name))

    tool =
      IntellectualClub.ToolsFixtures.create_tool_instance!(actor,
        type: "native-artifact-reader",
        name: "#{name} Artifact Reader",
        alias: "artifacts"
      )

    IntellectualClub.ToolsFixtures.create_bot_tool_binding!(actor, bot, tool)
    bot
  end
end
