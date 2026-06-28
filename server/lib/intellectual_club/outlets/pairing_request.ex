defmodule IntellectualClub.Outlets.PairingRequest do
  @moduledoc """
  A short-lived pairing request for an outlet runner (device flow).

  The server stores only the hash of `device_code`, never the raw value.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Outlets

  postgres do
    table("outlet_pairing_requests")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:device_code_hash], name: "outlet_pairing_requests_device_code_hash_index")

      index([:status, :expires_at, :created_at],
        name: "outlet_pairing_requests_status_expires_created_index"
      )
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :user_code, :string do
      allow_nil?(false)
    end

    attribute :device_code_hash, :string do
      allow_nil?(false)
    end

    attribute :runner_kind, :string do
      allow_nil?(false)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :requested_name, :string do
      allow_nil?(false)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :created_ip, :string do
      allow_nil?(true)
    end

    attribute :created_user_agent, :string do
      allow_nil?(false)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
    end

    attribute :status, :string do
      allow_nil?(false)
      default("pending")
      constraints(trim?: false, allow_empty?: false)
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil?(false)
    end

    attribute :approved_at, :utc_datetime_usec do
      allow_nil?(true)
    end

    attribute :delivered_at, :utc_datetime_usec do
      allow_nil?(true)
    end

    attribute :consumed_at, :utc_datetime_usec do
      allow_nil?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :approved_by, IntellectualClub.Accounts.User,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :tool_instance, IntellectualClub.Tools.ToolInstance,
      allow_nil?: true,
      attribute_type: :integer
  end

  identities do
    identity(:unique_user_code, [:user_code])
  end

  actions do
    defaults([:read])

    create :start do
      accept([
        :user_code,
        :device_code_hash,
        :runner_kind,
        :requested_name,
        :created_ip,
        :created_user_agent,
        :metadata,
        :status,
        :expires_at
      ])
    end

    update :update do
      accept([
        :runner_kind,
        :requested_name,
        :metadata,
        :status,
        :expires_at,
        :approved_at,
        :delivered_at,
        :consumed_at,
        :approved_by_id,
        :tool_instance_id
      ])

      require_atomic?(false)
    end
  end
end
