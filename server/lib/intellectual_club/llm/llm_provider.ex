defmodule IntellectualClub.Llm.LlmProvider do
  @moduledoc """
  Provider configuration for LLM API calls.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Llm,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias IntellectualClub.Duplication
  alias IntellectualClub.Llm.Changes.ValidateProviderAuth

  sqlite do
    table("llm_providers")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("llm_providers")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :type, :atom do
      allow_nil?(false)
      public?(true)
      default(:openrouter_chat_completion)

      constraints(one_of: [:openrouter_chat_completion, :responses, :demo])
    end

    attribute :auth_method, :atom do
      allow_nil?(false)
      public?(true)
      default(:api_key)

      constraints(one_of: [:api_key, :openai_oauth_refresh_token])
    end

    attribute :base_url, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :api_key, :string do
      allow_nil?(true)
    end

    attribute :oauth_refresh_token, :string do
      allow_nil?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    has_many :configurations, IntellectualClub.Llm.LlmConfiguration do
      destination_attribute(:provider_id)
    end
  end

  calculations do
    calculate :credentials_present, {:array, :string}, fn records, _context ->
      Enum.map(records, fn record ->
        credentials = []

        credentials =
          if credential_present?(Map.get(record, :api_key)) do
            ["api_key" | credentials]
          else
            credentials
          end

        credentials =
          if credential_present?(Map.get(record, :oauth_refresh_token)) do
            ["oauth_refresh_token" | credentials]
          else
            credentials
          end

        Enum.reverse(credentials)
      end)
    end do
      public? true
      load [:api_key, :oauth_refresh_token]
    end

    calculate :can_edit, :boolean, expr(owner_id == ^actor(:id)) do
      public?(true)
    end

    calculate :shared_incoming,
              :boolean,
              expr(
                owner_id != ^actor(:id) and
                  exists(configurations.shares.user_group.memberships, user_id == ^actor(:id))
              ) do
      public?(true)
    end

    calculate :shared_outgoing, :boolean, expr(configurations.exists(shares)) do
      public?(true)
    end
  end

  json_api do
    type "llm-providers"
  end

  actions do
    defaults([:read, :destroy])

    read :api_read do
      prepare fn query, _context ->
        Ash.Query.load(query, [:credentials_present])
      end
    end

    create :create do
      accept([:name, :type, :auth_method, :base_url, :api_key, :oauth_refresh_token])
      change(relate_actor(:owner))
      change({ValidateProviderAuth, []})
    end

    create :duplicate do
      argument :id, :integer do
        allow_nil?(false)
      end

      change(relate_actor(:owner))

      change fn changeset, _context ->
        actor = changeset.context[:private][:actor]
        source_id = Ash.Changeset.get_argument(changeset, :id)

        source =
          __MODULE__
          |> Ash.get!(source_id, actor: actor)

        preserve_credentials? = Duplication.owned_by_actor?(source.owner_id, actor)

        changeset
        |> Ash.Changeset.put_context(:duplicate_without_credentials, !preserve_credentials?)
        |> Ash.Changeset.change_attributes(%{
          name: Duplication.next_copy_label(source.name),
          type: source.type,
          auth_method: source.auth_method,
          base_url: source.base_url,
          api_key: if(preserve_credentials?, do: source.api_key, else: nil),
          oauth_refresh_token:
            if(preserve_credentials?, do: source.oauth_refresh_token, else: nil)
        })
      end

      change({ValidateProviderAuth, []})
    end

    update :update do
      accept([:name, :type, :auth_method, :base_url, :api_key, :oauth_refresh_token])
      require_atomic?(false)
      change({ValidateProviderAuth, []})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     exists(configurations.shares.user_group.memberships, user_id == ^actor(:id))
                   )
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end

  defp credential_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp credential_present?(_value), do: false
end
