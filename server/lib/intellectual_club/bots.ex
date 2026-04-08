defmodule IntellectualClub.Bots do
  @moduledoc """
  Bot configuration domain (Ash).
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(IntellectualClub.Bots.Bot)
    resource(IntellectualClub.Bots.BotShare)
    resource(IntellectualClub.Bots.BotCompatibleConfigurationTag)
    resource(IntellectualClub.Bots.BotKnowledgeBlock)
  end

  json_api do
    routes do
      base_route "/bots", IntellectualClub.Bots.Bot do
        index :read,
          default_fields: [
            :name,
            :blocks_count,
            :image,
            :can_edit,
            :shared_incoming,
            :shared_outgoing,
            :context_soft_limit_percent,
            :created_at,
            :updated_at,
            :sort_activity_at
          ]

        get(:read,
          default_fields: [
            :name,
            :image,
            :can_edit,
            :shared_incoming,
            :shared_outgoing,
            :first_messages,
            :variables,
            :max_tool_rounds,
            :context_soft_limit_percent,
            :supports_file_processing,
            :max_file_size_bytes,
            :history_mode,
            :created_at,
            :updated_at,
            :sort_activity_at
          ]
        )

        post(:create)
        post(:duplicate, route: "/:id/duplicate")
        patch(:update)
        delete(:destroy)
      end

      base_route "/bot-knowledge-blocks", IntellectualClub.Bots.BotKnowledgeBlock do
        index :read
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end

      base_route "/bot-compatible-configuration-tags",
                 IntellectualClub.Bots.BotCompatibleConfigurationTag do
        index :read
        get(:read)
        post(:create)
        delete(:destroy)
      end
    end
  end
end
