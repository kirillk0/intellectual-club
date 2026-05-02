defmodule IntellectualClub.Knowledge do
  @moduledoc """
  Knowledge domain (Ash).
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(IntellectualClub.Knowledge.KnowledgeBlock)
    resource(IntellectualClub.Knowledge.KnowledgeBlockTag)
    resource(IntellectualClub.Knowledge.KnowledgeTag)
  end

  json_api do
    routes do
      base_route "/knowledge-blocks", IntellectualClub.Knowledge.KnowledgeBlock do
        index :search,
          default_fields: [
            :name,
            :version,
            :token_count,
            :image,
            :can_edit,
            :shared_incoming,
            :shared_outgoing
          ]

        get(:read,
          default_fields: [
            :name,
            :version,
            :content,
            :variables,
            :external_id,
            :token_count,
            :image,
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

      base_route "/knowledge-tags", IntellectualClub.Knowledge.KnowledgeTag do
        index :search
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end

      base_route "/knowledge-block-tags", IntellectualClub.Knowledge.KnowledgeBlockTag do
        index :read
        get(:read)
        post(:create)
        delete(:destroy)
      end
    end
  end
end
