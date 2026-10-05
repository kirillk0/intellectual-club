defmodule IntellectualClub.Chat.LinkedForkCleanupLocksUsageFixture do
  @moduledoc """
  Owner-authorized teardown of committed concurrency-test fixtures only.

  The production accounting/task resources intentionally have no destroy action.
  This projection neither manages the schema nor exposes an application route.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat.LinkedForkCleanupLocksFixtureDomain,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_usage_records")
    repo(IntellectualClub.Repo)
    migrate?(false)
  end

  attributes do
    integer_primary_key(:id)
    attribute(:usage_user_id_snapshot, :integer, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy])
  end

  policies do
    policy action_type([:read, :destroy]) do
      authorize_if expr(usage_user_id_snapshot == ^actor(:id))
    end
  end
end
