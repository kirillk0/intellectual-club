defmodule IntellectualClub.Accounts.Token do
  @moduledoc """
  Token resource used by AshAuthentication.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Accounts,
    extensions: [AshAuthentication.TokenResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("tokens")
    repo(IntellectualClub.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end
end
