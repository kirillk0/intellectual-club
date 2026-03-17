defmodule IntellectualClub.Knowledge.KnowledgeTag do
  @moduledoc """
  A hierarchical tag for organizing knowledge blocks.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Knowledge,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedOwnedByActor
  alias IntellectualClub.Knowledge.Changes.SetTagFullName
  alias IntellectualClub.Knowledge.Validations.PreventTagCycles

  require Ash.Query

  sqlite do
    table("knowledge_tags")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("knowledge_tags")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :full_name, :string do
      allow_nil?(false)
      public?(true)
      default("")
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :parent, __MODULE__,
      allow_nil?: true,
      public?: true,
      attribute_type: :integer

    has_many :children, __MODULE__ do
      destination_attribute(:parent_id)
    end
  end

  identities do
    identity(:unique_full_name, [:owner_id, :full_name])
  end

  json_api do
    type "knowledge-tags"
  end

  actions do
    defaults([:read, :destroy])

    read :search do
      argument :q, :string do
        allow_nil?(true)
        public?(true)
      end

      prepare fn query, _context ->
        maybe_filter_by_query(query)
      end
    end

    create :create do
      accept([:name, :parent_id])
      change(relate_actor(:owner))
      change({RequireRelatedOwnedByActor, relationships: [:parent], required?: false})
      change({SetTagFullName, []})
    end

    update :update do
      accept([:name, :parent_id])
      require_atomic?(false)
      validate({PreventTagCycles, []}, where: [changing(:parent_id)])
      change({RequireRelatedOwnedByActor, relationships: [:parent], required?: false})
      change({SetTagFullName, []})
    end
  end

  defp maybe_filter_by_query(query) do
    q =
      case Ash.Query.get_argument(query, :q) do
        q when is_binary(q) -> String.trim(q)
        _ -> ""
      end

    if q == "" do
      query
    else
      Ash.Query.filter(query, contains(name, ^q) or contains(full_name, ^q))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
