defmodule IntellectualClub.Tools.ToolInstance do
  @moduledoc """
  A user-owned configured tool instance.

  Secrets are stored server-side and must never be sent to LLM providers.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Tools,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias IntellectualClub.Duplication
  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.Registry
  alias IntellectualClub.Tools.Changes.DeleteToolDependents
  alias IntellectualClub.Tools.Changes.MergeSecretsPatch
  alias IntellectualClub.Tools.Changes.ValidatePositiveRpsLimit
  alias IntellectualClub.Tools.ToolFunction
  alias IntellectualClub.Tools.Changes.ValidateToolType

  sqlite do
    table("tool_instances")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("tool_instances")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :type, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :config, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :secrets, :map do
      allow_nil?(false)
      default(%{})
      sensitive?(true)
    end

    attribute :max_output_tokens, :integer do
      allow_nil?(false)
      public?(true)
      default(20_000)
      constraints(min: 0)
    end

    attribute :rps_limit, :float do
      allow_nil?(true)
      public?(true)
    end

    attribute :last_discovered_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :last_discovery_error, :string do
      allow_nil?(false)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    has_many :bot_bindings, IntellectualClub.Tools.BotToolBinding do
      destination_attribute(:tool_instance_id)
    end

    has_many :chat_bindings, IntellectualClub.Tools.ChatToolBinding do
      destination_attribute(:tool_instance_id)
    end

    has_many :functions, IntellectualClub.Tools.ToolFunction do
      destination_attribute(:tool_instance_id)
      public?(true)
    end
  end

  calculations do
    calculate :secrets_present, {:array, :string}, fn records, _context ->
      Enum.map(records, fn record ->
        secrets =
          record
          |> Map.get(:secrets)
          |> case do
            %{} = secrets -> secrets
            _ -> %{}
          end

        tool_type =
          record
          |> Map.get(:type, "")
          |> to_string()
          |> String.trim()

        schema =
          try do
            Registry.driver_for_type!(tool_type).secrets_schema()
          rescue
            _ -> nil
          end

        schema
        |> secrets_schema_properties()
        |> Enum.flat_map(fn {raw_key, raw_spec} ->
          key = raw_key |> to_string() |> String.trim()

          if key == "" do
            []
          else
            candidate_keys = [key | secrets_schema_aliases(raw_spec)]

            present? =
              Enum.any?(candidate_keys, fn candidate ->
                value = Map.get(secrets, candidate)
                credential_present?(value)
              end)

            if present?, do: [key], else: []
          end
        end)
      end)
    end do
      public? true
      load [:type, :secrets]
    end

    calculate :outlet_online, :boolean, fn records, _context ->
      Enum.map(records, &outlet_online?/1)
    end do
      public? true
      load [:type, :config]
    end

    calculate :can_edit, :boolean, expr(owner_id == ^actor(:id)) do
      public?(true)
    end

    calculate :shared_incoming,
              :boolean,
              expr(
                owner_id != ^actor(:id) and
                  exists(
                    bot_bindings,
                    enabled == true and sharing_mode == :shared and
                      exists(bot.shares.user_group.memberships, user_id == ^actor(:id))
                  )
              ) do
      public?(true)
    end

    calculate :shared_outgoing,
              :boolean,
              expr(
                exists(
                  bot_bindings,
                  enabled == true and sharing_mode == :shared and bot.exists(shares)
                )
              ) do
      public?(true)
    end
  end

  json_api do
    type "tool-instances"
    includes([:functions])
  end

  actions do
    defaults([])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteToolDependents, []})
    end

    read :primary_read do
      primary?(true)
    end

    read :read do
      prepare fn query, _context ->
        Ash.Query.load(query, [:secrets_present])
      end
    end

    create :create do
      accept([:type, :name, :config, :secrets, :max_output_tokens, :rps_limit])
      change(relate_actor(:owner))
      change({ValidateToolType, []})
      change({ValidatePositiveRpsLimit, []})
      change({MergeSecretsPatch, []})
    end

    create :duplicate do
      argument :id, :integer do
        allow_nil?(false)
      end

      change(relate_actor(:owner))

      change fn changeset, _context ->
        actor = changeset.context[:private][:actor]
        source_id = Ash.Changeset.get_argument(changeset, :id)
        source = Ash.get!(__MODULE__, source_id, actor: actor)
        preserve_secrets? = Duplication.owned_by_actor?(source.owner_id, actor)

        functions =
          ToolFunction
          |> Ash.Query.filter(tool_instance_id == ^source.id)
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!(actor: actor)

        changeset
        |> Ash.Changeset.change_attributes(%{
          type: source.type,
          name: Duplication.next_copy_label(source.name),
          config: source.config,
          secrets: if(preserve_secrets?, do: source.secrets, else: %{}),
          max_output_tokens: source.max_output_tokens,
          rps_limit: source.rps_limit
        })
        |> Ash.Changeset.put_context(
          :duplicate_function_specs,
          Enum.map(functions, fn function ->
            %{
              name: function.name,
              description: function.description,
              parameters_schema: function.parameters_schema,
              enabled: function.enabled,
              discovered_at: function.discovered_at
            }
          end)
        )
        |> Ash.Changeset.after_action(fn changeset, duplicated ->
          actor = changeset.context[:private][:actor]

          changeset.context[:duplicate_function_specs]
          |> List.wrap()
          |> Enum.reduce_while({:ok, duplicated}, fn spec, {:ok, duplicated} ->
            ToolFunction
            |> Ash.Changeset.for_create(
              :create,
              Map.put(spec, :tool_instance_id, duplicated.id),
              actor: actor
            )
            |> Ash.create()
            |> case do
              {:ok, _function} -> {:cont, {:ok, duplicated}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
        end)
      end

      change({ValidateToolType, []})
      change({ValidatePositiveRpsLimit, []})
      change({MergeSecretsPatch, []})
    end

    update :update do
      accept([:name, :config, :secrets, :max_output_tokens, :rps_limit])
      require_atomic?(false)
      change({ValidatePositiveRpsLimit, []})
      change({MergeSecretsPatch, []})
    end

    update :update_discovery_metadata do
      accept([:last_discovered_at, :last_discovery_error])
      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     exists(
                       bot_bindings,
                       enabled == true and sharing_mode == :shared and
                         exists(bot.shares.user_group.memberships, user_id == ^actor(:id))
                     )
                   )
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end

  defp outlet_online?(record) do
    type =
      record
      |> Map.get(:type, "")
      |> to_string()
      |> String.trim()

    if type == "outlet" do
      Runtime.online?(record)
    else
      false
    end
  end

  defp credential_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp credential_present?(_value), do: false

  defp secrets_schema_properties(nil), do: %{}

  defp secrets_schema_properties(%{} = schema) do
    schema
    |> Map.get("properties", Map.get(schema, :properties))
    |> case do
      %{} = props -> props
      _ -> %{}
    end
  end

  defp secrets_schema_properties(_other), do: %{}

  defp secrets_schema_aliases(raw_spec) when is_map(raw_spec) do
    raw_spec
    |> Map.get("x-aliases", Map.get(raw_spec, :"x-aliases", []))
    |> List.wrap()
    |> Enum.map(fn value -> value |> to_string() |> String.trim() end)
    |> Enum.filter(&(&1 != ""))
  end

  defp secrets_schema_aliases(_other), do: []
end
