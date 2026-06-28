defmodule IntellectualClub.Accounts do
  @moduledoc """
  Accounts domain (Ash).

  Responsible for user records and authentication-related resources.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshJsonApi.Domain]

  resources do
    resource(IntellectualClub.Accounts.User)
    resource(IntellectualClub.Accounts.UserGroup)
    resource(IntellectualClub.Accounts.UserGroupMembership)
    resource(IntellectualClub.Accounts.UserKnowledgeBlock)
    resource(IntellectualClub.Accounts.Token)
  end

  json_api do
    routes do
      base_route "/users", IntellectualClub.Accounts.User do
        index(:read)
        get(:read)
        post(:create)
        patch(:update)
        patch(:reset_password, route: "/:id/reset-password")
        delete(:destroy)
      end

      base_route "/user-groups", IntellectualClub.Accounts.UserGroup do
        index(:admin_read)
        get(:admin_read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end

      base_route "/user-knowledge-blocks", IntellectualClub.Accounts.UserKnowledgeBlock do
        index(:read)
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end
    end
  end

  admin do
    show?(true)
    show_resources([IntellectualClub.Accounts.User, IntellectualClub.Accounts.UserGroup])
  end
end
