defmodule IntellectualClub.Files.ImageVerdict do
  @moduledoc """
  Remembered result of the structural image check for one payload, keyed by its
  SHA-256.

  `check_version` identifies the rule set that produced `status`, `mime_type`,
  dimensions and `reason`; rows from other rule sets are recomputed on the next
  cold load. The verdict depends only on the bytes: what a model provider did
  with an image is recorded per configuration in
  `IntellectualClub.Files.ImageProviderVerdict`.

  Access goes through `IntellectualClub.Files.ImageVerdicts`.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Files

  postgres do
    table("image_verdicts")
    repo(IntellectualClub.Repo)
  end

  attributes do
    attribute :sha256, :string do
      primary_key?(true)
      allow_nil?(false)
      constraints(max_length: 64, min_length: 64)
    end

    attribute :check_version, :integer do
      allow_nil?(false)
      constraints(min: 0)
    end

    attribute :status, :atom do
      allow_nil?(false)
      constraints(one_of: [:valid, :invalid])
    end

    attribute :mime_type, :string
    attribute :width, :integer, constraints: [min: 1]
    attribute :height, :integer, constraints: [min: 1]
    attribute :reason, :string, constraints: [max_length: 200]

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read])

    create :record do
      description("Upserts the structural result of the current rules.")
      accept([:sha256, :check_version, :status, :mime_type, :width, :height, :reason])
      upsert?(true)

      upsert_fields([
        :check_version,
        :status,
        :mime_type,
        :width,
        :height,
        :reason,
        :updated_at
      ])
    end
  end
end
