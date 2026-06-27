defmodule IntellectualClub.Files.File do
  @moduledoc """
  Logical file record.

  Multiple rows may point to the same payload identified by `sha256`.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Files

  sqlite do
    table("files")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("files")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :external_id, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :sha256, :string do
      allow_nil?(false)
    end

    attribute :filename, :string do
      allow_nil?(false)
    end

    attribute :size_bytes, :integer do
      allow_nil?(false)
      constraints(min: 0)
    end

    attribute :mime_type, :string do
      allow_nil?(false)
    end

    attribute :storage_backend, :atom do
      allow_nil?(false)
      default(:fs)
      constraints(one_of: [:db, :fs])
    end

    create_timestamp(:created_at)
  end

  identities do
    identity(:unique_external_id, [:external_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:sha256, :filename, :size_bytes, :mime_type, :storage_backend])
    end

    update :update_storage_backend do
      accept([:storage_backend])
    end
  end
end
