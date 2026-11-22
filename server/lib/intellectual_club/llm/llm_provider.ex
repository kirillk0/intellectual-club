defmodule IntellectualClub.Llm.LlmProvider do
  @moduledoc """
  Provider configuration for LLM API calls.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Llm,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Duplication
  alias IntellectualClub.Llm.Changes.ValidateProviderAuth
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.Validations.ValidCustomHeaders

  require Ash.Query

  @editable_fields ~w(name type auth_method base_url api_key oauth_refresh_token custom_headers)a

  postgres do
    table("llm_providers")
    repo(IntellectualClub.Repo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :type, :string do
      allow_nil?(false)
      public?(true)
      default("openrouter_chat_completion")
    end

    attribute :auth_method, :string do
      allow_nil?(false)
      public?(true)
      default("api_key")
    end

    attribute :base_url, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :custom_headers, :map do
      allow_nil?(false)
      default(%{})
      constraints(preserve_nil_values?: true)
      sensitive?(true)
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

    # The private attribute is available to generation for shared configurations.
    # Only expose its contents to the owner in JSON:API, even on explicit field selection.
    calculate :editable_custom_headers,
              :map,
              expr(if(owner_id == ^actor(:id), do: custom_headers, else: %{})) do
      public?(true)
      sensitive?(true)
      filterable?(false)
      sortable?(false)
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

    calculate :shared_outgoing, :boolean, expr(exists(configurations.shares, not is_nil(id))) do
      public?(true)
    end
  end

  json_api do
    type "llm-providers"
    field_names(editable_custom_headers: :custom_headers)
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)

      change fn changeset, context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          query =
            LlmConfiguration
            |> Ash.Query.filter(provider_id == ^changeset.data.id)
            |> Ash.Query.select([:model_name, :note])
            |> Ash.Query.sort(:id)

          case Ash.read(query, actor: context.actor, authorize?: context.authorize?) do
            {:ok, []} ->
              changeset

            {:ok, configurations} ->
              labels = Enum.map_join(configurations, "; ", &configuration_label/1)

              Ash.Changeset.add_error(changeset,
                message: "Cannot delete provider. It is used by configurations: #{labels}"
              )

            {:error, error} ->
              Ash.Changeset.add_error(changeset, error)
          end
        end)
      end
    end

    read :api_read do
      prepare fn query, _context ->
        Ash.Query.load(query, [:credentials_present])
      end
    end

    create :create do
      accept(@editable_fields)
      validate(ValidCustomHeaders)
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
          custom_headers: if(preserve_credentials?, do: source.custom_headers, else: %{}),
          api_key: if(preserve_credentials?, do: source.api_key, else: nil),
          oauth_refresh_token:
            if(preserve_credentials?, do: source.oauth_refresh_token, else: nil)
        })
      end

      change({ValidateProviderAuth, []})
    end

    update :update do
      accept(@editable_fields)
      validate(ValidCustomHeaders)
      require_atomic?(false)
      change({ValidateProviderAuth, []})
    end

    # Leaves the provider in the same "credentials missing" state as a
    # duplicate of a provider owned by someone else, so it is not validated.
    update :clear_oauth_refresh_token do
      public?(false)
      accept([])
      change(set_attribute(:oauth_refresh_token, nil))
      require_atomic?(false)
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

  defp configuration_label(configuration) do
    note = String.trim(configuration.note || "")
    label = "##{configuration.id} — #{configuration.model_name}"
    if note == "", do: label, else: "#{label} (#{note})"
  end
end
