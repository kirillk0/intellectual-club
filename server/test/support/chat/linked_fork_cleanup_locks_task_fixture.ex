defmodule IntellectualClub.Chat.LinkedForkCleanupLocksTaskFixture do
  @moduledoc """
  Owner-authorized teardown of committed concurrency-test fixtures only.

  The production accounting/task resources intentionally have no destroy action.
  This projection neither manages the schema nor exposes an application route.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat.LinkedForkCleanupLocksFixtureDomain,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("background_tasks")
    repo(IntellectualClub.Repo)
    migrate?(false)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :integer, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy])
  end

  policies do
    policy action_type([:read, :destroy]) do
      authorize_if expr(owner_id == ^actor(:id))
    end
  end
end
