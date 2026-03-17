defmodule IntellectualClub.Tools do
  @moduledoc """
  Tools domain (Ash).

  This domain stores tool instances, discovered functions, and bot bindings.
  Network I/O (discovery/execution) is intentionally implemented outside Ash.
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(IntellectualClub.Tools.ToolInstance)
    resource(IntellectualClub.Tools.ToolFunction)
    resource(IntellectualClub.Tools.BotToolBinding)
    resource(IntellectualClub.Tools.BotUserToolBinding)
  end

  json_api do
    routes do
      base_route "/tool-instances", IntellectualClub.Tools.ToolInstance do
        index(:read,
          default_fields: [
            :type,
            :name,
            :config,
            :max_output_tokens,
            :last_discovered_at,
            :last_discovery_error,
            :secrets_present,
            :outlet_online,
            :created_at,
            :updated_at,
            :can_edit,
            :shared_incoming,
            :shared_outgoing
          ]
        )

        get(:read,
          default_fields: [
            :type,
            :name,
            :config,
            :max_output_tokens,
            :last_discovered_at,
            :last_discovery_error,
            :secrets_present,
            :outlet_online,
            :created_at,
            :updated_at,
            :can_edit,
            :shared_incoming,
            :shared_outgoing
          ]
        )

        post(:create)
        post(:duplicate, route: "/:id/duplicate")
        patch(:update)
        delete(:destroy)
      end

      base_route "/tool-functions", IntellectualClub.Tools.ToolFunction do
        index(:read)
        get(:read)
        patch(:update)
        delete(:destroy)
      end

      base_route "/bot-tool-bindings", IntellectualClub.Tools.BotToolBinding do
        index(:read)
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end

      base_route "/bot-user-tool-bindings", IntellectualClub.Tools.BotUserToolBinding do
        index(:read)
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end
    end
  end
end
