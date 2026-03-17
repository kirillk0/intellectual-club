defmodule IntellectualClub.AccountsFixtures do
  @moduledoc """
  Test helpers for Accounts and authentication.
  """

  alias IntellectualClub.Accounts.{User, UserGroup}

  def user_fixture(attrs \\ %{}) when is_map(attrs) do
    username = Map.get(attrs, :username, unique_username())
    password = Map.get(attrs, :password, "test-password-1234")
    is_admin = Map.get(attrs, :is_admin, false)

    user =
      User
      |> Ash.Changeset.for_create(
        :create,
        %{
          username: username,
          is_admin: is_admin,
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )
      |> Ash.create!()

    %{user: user, password: password}
  end

  def sign_in_conn(conn, %{user: user, password: password}) do
    sign_in_conn(conn, user.username, password)
  end

  def sign_in_conn(conn, username, password) when is_binary(username) and is_binary(password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, signed_in_user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "username" => username,
        "password" => password
      })

    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(signed_in_user)
  end

  def user_group_fixture(attrs \\ %{}) when is_map(attrs) do
    name = Map.get(attrs, :name, unique_group_name())

    users =
      attrs
      |> Map.get(:users, [])
      |> List.wrap()
      |> Enum.map(fn
        %{id: id} when is_integer(id) -> id
        id when is_integer(id) -> id
        _other -> nil
      end)
      |> Enum.reject(&is_nil/1)

    payload =
      %{name: name}
      |> maybe_put_users(users)

    group =
      UserGroup
      |> Ash.Changeset.for_create(:create, payload, authorize?: false)
      |> Ash.create!()

    %{group: group}
  end

  defp unique_username do
    "user_#{System.unique_integer([:positive])}"
  end

  defp unique_group_name do
    "group_#{System.unique_integer([:positive])}"
  end

  defp maybe_put_users(payload, []), do: payload
  defp maybe_put_users(payload, users), do: Map.put(payload, :users, users)
end
