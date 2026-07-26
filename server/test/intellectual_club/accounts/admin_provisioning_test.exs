defmodule IntellectualClub.Accounts.AdminProvisioningTest do
  use IntellectualClub.DataCase, async: true

  alias IntellectualClub.Accounts.{AdminProvisioning, User}

  test "creates an administrator that can authenticate" do
    username = "provisioned_admin_#{System.unique_integer([:positive])}"
    password = "provisioned-password-1234"

    assert {:ok, %User{username: ^username, is_admin: true} = user} =
             AdminProvisioning.create_admin(%{
               username: username,
               password: password,
               password_confirmation: password
             })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    assert {:ok, %User{id: user_id}} =
             AshAuthentication.Strategy.action(strategy, :sign_in, %{
               "username" => username,
               "password" => password
             })

    assert user_id == user.id
  end

  test "creates another administrator when administrators already exist" do
    %{user: existing_admin} = user_fixture(%{is_admin: true})
    username = "additional_admin_#{System.unique_integer([:positive])}"
    password = "additional-password-1234"

    assert {:ok, %User{username: ^username, is_admin: true}} =
             AdminProvisioning.create_admin(%{
               username: username,
               password: password,
               password_confirmation: password
             })

    assert {:ok, %User{is_admin: true}} = Ash.get(User, existing_admin.id, authorize?: false)
  end

  test "does not modify an existing user" do
    original_password = "original-password-1234"

    %{user: existing_user} =
      user_fixture(%{is_admin: false, password: original_password})

    assert {:error, :username_taken} =
             AdminProvisioning.create_admin(%{
               username: existing_user.username,
               password: "replacement-password-1234",
               password_confirmation: "replacement-password-1234"
             })

    assert {:ok, %User{is_admin: false}} = Ash.get(User, existing_user.id, authorize?: false)

    strategy = AshAuthentication.Info.strategy!(User, :password)

    assert {:ok, %User{id: user_id}} =
             AshAuthentication.Strategy.action(strategy, :sign_in, %{
               "username" => existing_user.username,
               "password" => original_password
             })

    assert user_id == existing_user.id
  end
end
