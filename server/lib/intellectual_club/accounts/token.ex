defmodule IntellectualClub.Accounts.Token do
  @moduledoc """
  Token resource used by AshAuthentication.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Accounts,
    extensions: [AshAuthentication.TokenResource],
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table("tokens")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("tokens")
    repo(IntellectualClub.PostgresRepo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end
end
