defmodule IntellectualClub.Files.ImageProviderVerdict do
  @moduledoc """
  What one LLM configuration did with one image payload, keyed by the payload
  SHA-256 and the configuration: `:accepted` it in a completed response or
  `:rejected` it with an image error.

  Unlike the structural `IntellectualClub.Files.ImageVerdict`, which depends only
  on the bytes, these are facts about a configuration: providers have different
  decoders and size limits, and one OpenRouter configuration may route models to
  different upstreams. Facts are deleted together with their configuration.

  Access goes through `IntellectualClub.Files.ImageProviderVerdicts`.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Files

  postgres do
    table("image_provider_verdicts")
    repo(IntellectualClub.Repo)

    references do
      reference(:llm_configuration, on_delete: :delete)
    end

    custom_indexes do
      index([:llm_configuration_id],
        name: "image_provider_verdicts_llm_configuration_id_index"
      )
    end
  end

  attributes do
    attribute :sha256, :string do
      primary_key?(true)
      allow_nil?(false)
      constraints(max_length: 64, min_length: 64)
    end

    attribute :status, :atom do
      allow_nil?(false)
      constraints(one_of: [:accepted, :rejected])
    end

    attribute :details, :string, constraints: [max_length: 1_000]

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration do
      primary_key?(true)
      allow_nil?(false)
      attribute_type(:integer)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :mark_rejected do
      description("Records a rejection, overwriting an earlier acceptance or rejection.")
      accept([:sha256, :llm_configuration_id, :details])
      change(set_attribute(:status, :rejected))
      upsert?(true)
      upsert_fields([:status, :details, :updated_at])
    end

    create :record_accepted do
      description("Records an acceptance unless any fact for the pair already exists.")
      accept([:sha256, :llm_configuration_id])
      change(set_attribute(:status, :accepted))
      upsert?(true)
      upsert_fields([])
      # Never update an existing fact, in particular never undo a rejection.
      upsert_condition(expr(false))
    end
  end
end
