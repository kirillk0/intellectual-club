defmodule IntellectualClub.Accounts.AdminProvisioning do
  @moduledoc """
  Creates administrator accounts from trusted local provisioning commands.
  """

  alias IntellectualClub.Accounts.User

  require Ash.Query

  @type attributes :: %{
          required(:username) => String.t(),
          required(:password) => String.t(),
          required(:password_confirmation) => String.t()
        }

  @spec create_admin(attributes()) :: {:ok, User.t()} | {:error, :username_taken | term()}
  def create_admin(%{
        username: username,
        password: password,
        password_confirmation: password_confirmation
      }) do
    username = String.trim(username)

    case find_user(username) do
      {:ok, nil} ->
        User
        |> Ash.Changeset.for_create(
          :create,
          %{
            username: username,
            is_admin: true,
            password: password,
            password_confirmation: password_confirmation
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, %User{}} ->
        {:error, :username_taken}

      {:error, error} ->
        {:error, error}
    end
  end

  defp find_user(username) do
    User
    |> Ash.Query.filter(username == ^username)
    |> Ash.read_one(authorize?: false)
  end
end
